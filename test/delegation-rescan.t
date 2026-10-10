#! /usr/bin/env perl
use warnings;
use strict;

# rescandelegations: a staking key added after the owners had funded their
# addresses (importstakingkey migration) finds the marked outputs both in the
# stored blocks and in the blocks still in memory, and loads the whole
# address UTXO.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Test::Send qw(send_block send_raw_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Block;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format scripthash_by_address pubkeyhash_by_pubkey);
use QBitcoin::Script::Delegation qw(delegation_address);
use QBitcoin::StakingKey;
use QBitcoin::Delegation;
use QBitcoin::Wallet::UTXO ();
use QBitcoin::Coins;

$config->{regtest} = 1;
$config->{accept_delegations} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

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
sub rpc {
    my ($cmd, @args) = @_;
    my $rpc = TestRPC->new;
    $rpc->cmd($cmd);
    $rpc->args(\@args);
    return $rpc if $rpc->validate(TestRPC->params($cmd)) != 0;
    my $func = "cmd_$cmd";
    $rpc->$func;
    return $rpc;
}

# The delegate's staking key exists only off this node for now: the owners
# know its pubkeyhash and fund their addresses
my $staking_pk  = generate_keypair(CRYPT_ALGO_ECDSA);
my $staking_pkh = pubkeyhash_by_pubkey($staking_pk->pubkey_by_privkey, CRYPT_ALGO_ECDSA);
sub owner_pkh { pubkeyhash_by_pubkey(generate_keypair(CRYPT_ALGO_ECDSA)->pubkey_by_privkey, CRYPT_ALGO_ECDSA) }
my $owner1 = owner_pkh();
my $owner2 = owner_pkh();
my $address1 = delegation_address($owner1, $staking_pkh);
my $address2 = delegation_address($owner2, $staking_pkh);
my $sh1 = scripthash_by_address($address1);
my $sh2 = scripthash_by_address($address2);

QBitcoin::Coins->init();
sub coinbase_tx {
    my ($value, $scripthash, $data) = @_;
    my $out = QBitcoin::TXO->new_txo(value => $value, scripthash => $scripthash, num => 0, data => $data // "");
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
    return $tx;
}
sub delegated_value { sum0(map { $_->value } QBitcoin::Wallet::UTXO::myutxo_delegated()) }

# Block 0: the first address funded (unmarked, then marked); goes to the database below
send_block(0, "a0", undef, 1,
    coinbase_tx(50000, $sh1),
    coinbase_tx(200000000, $sh1, TXO_DATA_DELEGATION . $owner1),
);
# Store the blocks (the main loop does it for the blocks older than INCORE_TIME)
my $height = 0;
while ($height < INCORE_LEVELS) {
    $height++;
    send_block($height, "a$height", "a" . ($height - 1), $height + 1) or die "Block $height rejected\n";
}
QBitcoin::Block->store_blocks();
is(QBitcoin::Block->max_db_height, $height, "blocks stored in the database");
# The second address funded in a block still in memory
$height++;
send_block($height, "a$height", "a" . ($height - 1), $height + 1,
    coinbase_tx(300000000, $sh2, TXO_DATA_DELEGATION . $owner2),
);
is(QBitcoin::Block->blockchain_height, $height, "blocks accepted");
is(QBitcoin::Block->max_db_height, $height - 1, "the last block is in memory only");
is(scalar(QBitcoin::Delegation->list), 0, "nothing registered without the staking key");

# Import the key: the delegations are not known yet, the scan finds them
my $res = rpc("importstakingkey", wallet_import_format($staking_pk->pk_serialize))->_rpc_result;
ok($res && $res->{pubkeyhash}, "staking key imported");
is(scalar(QBitcoin::Delegation->list), 0, "import alone registers nothing");

$res = rpc("rescandelegations")->_rpc_result;
is($res->{registered}, 2, "rescan registered both addresses");
is_deeply([ sort @{$res->{addresses}} ], [ sort $address1, $address2 ], "their addresses");
is_deeply([ sort map { $_->address } QBitcoin::Delegation->list ], [ sort $address1, $address2 ], "delegations stored");
is(delegated_value(), 50000 + 200000000 + 300000000, "whole address utxo loaded, the unmarked output too");
is(scalar(QBitcoin::Delegation->take_pending_load), 0, "nothing left pending");

$res = rpc("rescandelegations")->_rpc_result;
is($res->{registered}, 0, "second scan registers nothing");

$config->{accept_delegations} = 0;
ok(rpc("rescandelegations")->_rpc_error, "refused when accept_delegations is disabled");

done_testing();
