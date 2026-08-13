#! /usr/bin/env perl
use warnings;
use strict;

# Delegated staking end to end: the RPC setup flow for the delegate, the
# owner and the both-keys-on-one-node case; block generation staking a
# delegated UTXO under the covenant with the delegate's reward share; the
# owner spend of the delegated coins.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Test::Send qw(send_block send_raw_tx);
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Block;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Generate;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey scripthash_by_address address_by_hash pubkeyhash_str pubkeyhash_by_pubkey);
use QBitcoin::Script qw(script_eval op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::MyAddress;
use QBitcoin::StakingKey;
use QBitcoin::Delegation;
use QBitcoin::Wallet::UTXO ();
use QBitcoin::Coins;

$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
my $static_reward = 200000000;
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { $static_reward });

# Minimal RPC handler for testing cmd_* without the HTTP layer (see rpc-address-peer.t)
{
    package TestRPC;
    use warnings;
    use strict;
    use QBitcoin::Accessors qw(mk_accessors);
    use Role::Tiny::With;
    with 'QBitcoin::RPC::Validate';
    with 'QBitcoin::RPC::Commands';
    mk_accessors(qw(cmd args _rpc_result _rpc_error _rpc_error_code));
    sub new { bless {}, shift }
    sub response_ok    { $_[0]->_rpc_result($_[1] // "ok"); 0 }
    sub response_error { $_[0]->_rpc_error($_[1]); $_[0]->_rpc_error_code($_[2]); -1 }
}

# Validate the params (converting them like the real RPC layer does), then call
# the command; returns the TestRPC object for inspecting the result
sub rpc {
    my ($cmd, @args) = @_;
    my $rpc = TestRPC->new;
    $rpc->cmd($cmd);
    $rpc->args(\@args);
    if ($rpc->validate(TestRPC->params($cmd)) != 0) {
        return $rpc;
    }
    my $func = "cmd_$cmd";
    $rpc->$func;
    return $rpc;
}

# --- Delegate side: staking key ---

my $res = rpc("getnewstakingkey")->_rpc_result;
ok($res && $res->{pubkeyhash}, "getnewstakingkey returns pubkeyhash");
my $staking_pkh_str = $res->{pubkeyhash};
is(scalar(QBitcoin::StakingKey->list), 1, "staking key stored");

$res = rpc("liststakingkeys")->_rpc_result;
is_deeply($res, [ { pubkeyhash => $staking_pkh_str, algo => "ecdsa", delegations => 0 } ], "liststakingkeys");

# --- Owner side: new delegated address ---

$res = rpc("getnewaddress", "ecdsa", $staking_pkh_str)->_rpc_result;
ok($res && $res->{address} && $res->{private_key} && $res->{pubkeyhash}, "getnewaddress with delegate pubkeyhash");
my ($deleg_address, $owner_wif, $owner_pkh_str) = @$res{qw(address private_key pubkeyhash)};

# Both sides derive the same address
$res = rpc("createdelegationaddress", $owner_pkh_str, $staking_pkh_str)->_rpc_result;
is($res->{address}, $deleg_address, "createdelegationaddress matches getnewaddress");

# --- Delegate side: register the delegation (the owner key is NOT here yet) ---

$res = rpc("adddelegationaddress", $owner_pkh_str)->_rpc_result;
is($res->{address}, $deleg_address, "adddelegationaddress derives the same address");
is(scalar(QBitcoin::Delegation->list), 1, "delegation stored");

$res = rpc("getaddressinfo", $deleg_address)->_rpc_result;
is($res->{delegation}, "delegate", "getaddressinfo: delegate role");
ok($res->{stakeonly}, "getaddressinfo: stakeonly");
ok(!$res->{ismine}, "getaddressinfo: not mine");
is($res->{owner_pubkeyhash}, $owner_pkh_str, "getaddressinfo: owner pubkeyhash");

$res = rpc("listmyaddresses")->_rpc_result;
ok($res->{$deleg_address}, "stakeonly address listed in listmyaddresses");
is($res->{$deleg_address}{delegation}, "delegate", "listmyaddresses: delegate role");
ok($res->{$deleg_address}{stakeonly}, "listmyaddresses: stakeonly flag");

# Owner-only case on the same node: another delegation address whose owner key
# is imported here, but no delegation row exists (some other node stakes it)
my $foreign_staking = generate_keypair(CRYPT_ALGO_ECDSA);
my $foreign_pkh_str = pubkeyhash_str(pubkeyhash_by_pubkey($foreign_staking->pubkey_by_privkey, CRYPT_ALGO_ECDSA));
$res = rpc("getnewaddress", "ecdsa", $foreign_pkh_str)->_rpc_result;
my $owner_only_address = $res->{address};
$res = rpc("importprivkey", $res->{private_key})->_rpc_result;
like($res, qr/imported/, "delegation owner key imported");
$res = rpc("getaddressinfo", $owner_only_address)->_rpc_result;
is($res->{delegation}, "owner", "getaddressinfo: owner role");
ok($res->{ismine}, "getaddressinfo: owner address is mine");
is($res->{delegate_pubkeyhash}, $foreign_pkh_str, "getaddressinfo: delegate pubkeyhash");
ok(!$res->{stakeonly}, "getaddressinfo: owner address is not stakeonly");

# The owner must not stake the delegated address (equivocation with the delegate)
$res = rpc("stakeaddress", $owner_only_address);
ok($res->_rpc_error, "stakeaddress refused for a delegation owner address");

# --- Block generation over a delegated UTXO ---

# Own staked address for the block generation
my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my ($own_address) = addresses_by_pubkey($pk->pubkey_by_privkey, CRYPT_ALGO_ECDSA);
my $myaddr = QBitcoin::MyAddress->create({
    private_key => wallet_import_format($pk->pk_serialize),
    address     => $own_address,
    staked      => 1,
});
my $own_sh = scalar $myaddr->scripthash;
my $deleg_sh = scripthash_by_address($deleg_address);

# The delegate keeps 25% of the reward
my $reward_address = address_by_hash("\x11" x 20);
my $reward_sh      = scripthash_by_address($reward_address);
$config->{reward_addr} = "$reward_address 0.25";
$config->{reward_to}   = "union";

QBitcoin::Coins->init();

# Fund both addresses with coinbase outputs in an external block
my @fund_tx;
foreach my $spec ([ 300000, $own_sh ], [ 100000, $deleg_sh ]) {
    my ($value, $scripthash) = @$spec;
    my $out = QBitcoin::TXO->new_txo(value => $value, scripthash => $scripthash, num => 0, data => "");
    my $tx = QBitcoin::Transaction->new(
        out           => [ $out ],
        in            => [],
        fee           => 0,
        tx_type       => TX_TYPE_COINBASE,
        coins_created => $value,
    );
    $tx->calculate_hash;
    $out->tx_in = $tx->hash;
    send_raw_tx($tx) or die "Can't send coinbase tx\n";
    push @fund_tx, $tx;
}
send_block(0, "a0", undef, 1, @fund_tx);
is(QBitcoin::Block->blockchain_height, 0, "funding block accepted");

is(sum0(map { $_->value } QBitcoin::Wallet::UTXO::myutxo_delegated()), 100000,
    "delegated utxo tracked");
is(sum0(map { $_->value } QBitcoin::TXO->my_utxo()), 300000,
    "delegated utxo not counted in the wallet balance");

block_hash("b1");
my $block1 = QBitcoin::Generate->generate(GENESIS_TIME + BLOCK_INTERVAL * FORCE_BLOCKS);
ok($block1, "block with the delegated stake generated") or done_testing, exit;
my ($stake_tx) = grep { $_->tx_type == TX_TYPE_STAKE } @{$block1->transactions};
ok($stake_tx, "stake transaction found");
is(scalar(@{$stake_tx->in}), 2, "stake tx spends both the own and the delegated utxo");

my %out_value = map { $_->scripthash => $_->value } @{$stake_tx->out};
# reward 200000000: 25% cut, the rest split by weight (equal age => by value)
is($out_value{$reward_sh}, 50000000, "the delegate's reward share");
is($out_value{$deleg_sh}, 100000 + 37500000, "delegated output: principal + reward part");
is($out_value{$own_sh}, 300000 + 112500000, "own output: value + reward part");

# The covenant script really passes for the delegated input
my ($deleg_num) = grep { $stake_tx->in->[$_]{txo}->scripthash eq $deleg_sh } 0 .. $#{$stake_tx->in};
my $deleg_in = $stake_tx->in->[$deleg_num];
is(scalar(@{$deleg_in->{siglist}}), 3, "delegate branch siglist");
ok(script_eval($deleg_in->{siglist}, $deleg_in->{txo}->redeem_script, $stake_tx, $deleg_num),
    "covenant script passes for the delegated input");

# ...and fails if the delegate tries to keep the principal
{
    my $steal = QBitcoin::Transaction->new(
        in      => [ { txo => $deleg_in->{txo} } ],
        out     => [ QBitcoin::TXO->new_txo(value => $deleg_in->{txo}->value, scripthash => $reward_sh) ],
        fee     => 0,
        tx_type => TX_TYPE_STAKE,
    );
    ok(!script_eval($deleg_in->{siglist}, $deleg_in->{txo}->redeem_script, $steal, 0),
        "covenant rejects redirecting the principal");
}

# --- Owner spend: import the owner key and spend the delegated output ---

$res = rpc("importprivkey", $owner_wif)->_rpc_result;
like($res, qr/imported/, "owner key imported on the delegate node");
$res = rpc("getaddressinfo", $deleg_address)->_rpc_result;
is($res->{delegation}, "both", "getaddressinfo: both roles on one node");

my ($new_deleg_out) = grep { $_->scripthash eq $deleg_sh } @{$stake_tx->out};
my $spend_out = QBitcoin::TXO->new_txo(value => $new_deleg_out->value, scripthash => "\x22" x 20, num => 0);
my $spend_tx = QBitcoin::Transaction->new(
    in            => [ { txo => $new_deleg_out } ],
    out           => [ $spend_out ],
    fee           => 0,
    tx_type       => TX_TYPE_STANDARD,
    received_time => time(),
);
$spend_tx->sign_transaction();
is(scalar(@{$spend_tx->in->[0]{siglist}}), 3, "owner branch siglist");
ok(script_eval($spend_tx->in->[0]{siglist}, $new_deleg_out->redeem_script, $spend_tx, 0),
    "owner spends the delegated coins");

done_testing();
