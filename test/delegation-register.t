#! /usr/bin/env perl
use warnings;
use strict;

# Delegation registration from the chain (config accept_delegations): the
# owner funds the covenant address with an output marked by
# TXO_DATA_DELEGATION . owner_pubkeyhash in its data field, and the delegate
# node registers the delegation when the address matches its staking key.
# Checks the option gate, the minimum value, marks for other delegates or of
# a wrong size, and the loading of the outputs confirmed on the address
# before the marked one (both an earlier block and the same block) when the
# stake transaction is built.

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
use QBitcoin::Generate;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey scripthash_by_address address_by_hash pubkeyhash_by_pubkey);
use QBitcoin::Script::Delegation qw(delegation_address);
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
# No reward for the external blocks (a sent block has no stake), the usual one for ours
my $static_reward = 0;
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { $static_reward });

# Delegate side: the staking key
my $staking_pk = generate_keypair(CRYPT_ALGO_ECDSA);
my $staking_key = QBitcoin::StakingKey->create({
    private_key => wallet_import_format($staking_pk->pk_serialize),
    pubkey      => $staking_pk->pubkey_by_privkey,
    algo        => CRYPT_ALGO_ECDSA,
});
ok($staking_key, "staking key created");

# Owner side: the owner key and the covenant address (nothing is sent to the delegate node)
sub owner_pkh { pubkeyhash_by_pubkey(generate_keypair(CRYPT_ALGO_ECDSA)->pubkey_by_privkey, CRYPT_ALGO_ECDSA) }
my $owner_pkh     = owner_pkh();
my $deleg_address = delegation_address($owner_pkh, $staking_key->pubkeyhash);
my $deleg_sh      = scripthash_by_address($deleg_address);
my $mark          = TXO_DATA_DELEGATION . $owner_pkh;

# Own staked address so that the node generates blocks
my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my ($own_address) = addresses_by_pubkey($pk->pubkey_by_privkey, CRYPT_ALGO_ECDSA);
my $myaddr = QBitcoin::MyAddress->create({
    private_key => wallet_import_format($pk->pk_serialize),
    address     => $own_address,
    staked      => 1,
});
my $own_sh = scalar $myaddr->scripthash;
$config->{reward_to} = "union";
QBitcoin::Coins->init();

# Coinbase outputs in an external block; distinct values keep the tx hashes distinct
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

# --- Option disabled: a marked output registers nothing ---

send_block(0, "a0", undef, 1,
    coinbase_tx(300000, $own_sh),
    coinbase_tx(50000, $deleg_sh),               # unmarked, before any registration
    coinbase_tx(200000000, $deleg_sh, $mark),    # marked, but accept_delegations is off
);
is(QBitcoin::Block->blockchain_height, 0, "block 0 accepted");
is(scalar(QBitcoin::Delegation->list), 0, "no registration while accept_delegations is off");
is(delegated_value(), 0, "no delegated utxo tracked");

# --- Option enabled ---

$config->{accept_delegations} = 1;

# Marks that must be ignored: for another delegate, of a wrong size, below the minimum
my $other_staking_pkh = pubkeyhash_by_pubkey(generate_keypair(CRYPT_ALGO_ECDSA)->pubkey_by_privkey, CRYPT_ALGO_ECDSA);
my $other_owner_pkh   = owner_pkh();
my $other_delegate_sh = scripthash_by_address(delegation_address($other_owner_pkh, $other_staking_pkh));
my $small_owner_pkh   = owner_pkh();
my $small_sh          = scripthash_by_address(delegation_address($small_owner_pkh, $staking_key->pubkeyhash));
my $short_owner_pkh   = owner_pkh();
my $short_sh          = scripthash_by_address(delegation_address($short_owner_pkh, $staking_key->pubkeyhash));

send_block(1, "a1", "a0", 2,
    coinbase_tx(70000, $deleg_sh),                                               # unmarked, same block, before the mark
    coinbase_tx(200000001, $deleg_sh, $mark),                                    # registers
    coinbase_tx(200000002, $other_delegate_sh, TXO_DATA_DELEGATION . $other_owner_pkh), # another delegate's key
    coinbase_tx(200000003, $short_sh, TXO_DATA_DELEGATION . substr($short_owner_pkh, 1)), # wrong size
    coinbase_tx(50000000, $small_sh, TXO_DATA_DELEGATION . $small_owner_pkh),    # 0.5 coin < min_delegation 1
);
is(QBitcoin::Block->blockchain_height, 1, "block 1 accepted");
my @delegations = QBitcoin::Delegation->list;
is(scalar(@delegations), 1, "exactly one delegation registered");
is($delegations[0]->address, $deleg_address, "the registered address");
is($delegations[0]->staking_key_id, $staking_key->id, "bound to the matching staking key");
is($delegations[0]->owner_pubkeyhash, $owner_pkh, "owner pubkeyhash from the mark");
is(delegated_value(), 200000001, "only the marked output tracked before the stake");
is(sum0(map { $_->value } QBitcoin::TXO->my_utxo()), 300000, "delegated utxo not counted in the wallet balance");

# Repeated mark for a registered address is a no-op
ok(!QBitcoin::Delegation->register_output(QBitcoin::TXO->new_txo(value => 300000000, scripthash => $deleg_sh, data => $mark)),
    "repeated mark registers nothing");

# --- The stake loads the whole address, including the outputs confirmed before the mark ---

$static_reward = 200000000;
block_hash("b2");
my $block2 = QBitcoin::Generate->generate(GENESIS_TIME + 2 * BLOCK_INTERVAL * FORCE_BLOCKS);
ok($block2, "block with the delegated stake generated") or done_testing, exit;
my ($stake_tx) = grep { $_->tx_type == TX_TYPE_STAKE } @{$block2->transactions};
ok($stake_tx, "stake transaction found");
my @deleg_in = grep { $_->{txo}->scripthash eq $deleg_sh } @{$stake_tx->in};
is(scalar(@deleg_in), 4, "all four outputs of the delegated address staked");
is(sum0(map { $_->{txo}->value } @deleg_in), 50000 + 200000000 + 70000 + 200000001, "their total value");
is(scalar(QBitcoin::Delegation->take_pending_load), 0, "pending load drained");
my ($deleg_out) = grep { $_->scripthash eq $deleg_sh } @{$stake_tx->out};
ok($deleg_out && $deleg_out->value >= 50000 + 200000000 + 70000 + 200000001, "covenant: principal paid back to the address");

done_testing();
