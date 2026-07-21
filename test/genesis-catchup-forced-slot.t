#! /usr/bin/env perl
use warnings;
use strict;

# After a restart the in-memory registry of published stakes is empty, so the node
# refuses to (re)stake the startup slot or any earlier one (self-equivocation guard).
# The genesis node is exempt for skipped forced slots: otherwise a restarted sole
# staker could never extend a stalled chain (the past-due forced slot stays at or
# before every future startup slot).

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Test::Send qw(send_tx $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Transaction;
use QBitcoin::Block;
use QBitcoin::Generate;
use QBitcoin::Generate::Control;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::Coins;

$config->{regtest} = 1;
$config->{genesis} = 1;
$config->{genesis_reward} = GENESIS_REWARD;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });

my $static_reward = 200000000;
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { $static_reward });

my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my $pubkey = $pk->pubkey_by_privkey;
my ($address) = addresses_by_pubkey($pubkey, CRYPT_ALGO_ECDSA);
QBitcoin::MyAddress->create({
    private_key => wallet_import_format($pk->pk_serialize),
    address     => $address,
    staked      => 1,
});

QBitcoin::Coins->init();

my $forced_interval = BLOCK_INTERVAL * FORCE_BLOCKS;

block_hash("a0");
my $block0 = QBitcoin::Generate->generate(GENESIS_TIME);
ok($block0, "Genesis block generated");

block_hash("a1");
my $block1 = QBitcoin::Generate->generate(GENESIS_TIME + $forced_interval);
ok($block1, "Forced block height 1 generated");
is(QBitcoin::Block->blockchain_height, 1, "Blockchain height 1");
ok(@{$block1->transactions} && $block1->transactions->[0]->is_stake && @{$block1->transactions->[0]->in},
    "Block 1 stake has inputs, the self-equivocation guard applies");

# Simulate a restart while the chain is stalled: the startup slot is far ahead of the
# chain tip, so every slot the node could stake is at or before the startup slot.
QBitcoin::Generate::Control->start_slot(timeslot(GENESIS_TIME + 100 * $forced_interval));

# A fee-paying mempool transaction makes generation reach the stake guard even in a
# non-forced slot (an empty non-forced slot is skipped long before the guard).
my $mempool_tx = send_tx(10, undef);
ok($mempool_tx, "Mempool transaction accepted");

$config->{genesis} = 0;
block_hash("b2");
my $skipped = QBitcoin::Generate->generate(GENESIS_TIME + 2 * $forced_interval);
ok(!$skipped, "Non-genesis node does not stake a skipped forced slot");
is(QBitcoin::Block->blockchain_height, 1, "Blockchain height still 1");

$config->{genesis} = 1;
block_hash("c2");
$skipped = QBitcoin::Generate->generate(GENESIS_TIME + 2 * $forced_interval + BLOCK_INTERVAL);
ok(!$skipped, "Genesis node does not stake a skipped non-forced slot");
is(QBitcoin::Block->blockchain_height, 1, "Blockchain height still 1");

block_hash("a2");
my $block2 = QBitcoin::Generate->generate(GENESIS_TIME + 2 * $forced_interval);
ok($block2, "Genesis node stakes the skipped forced slot");
is(QBitcoin::Block->blockchain_height, 2, "Blockchain height 2");
is(QBitcoin::Block->best_block->hash, "a2", "Catch-up block is the best block");
is(timeslot(QBitcoin::Block->best_block->time), timeslot(GENESIS_TIME + 2 * $forced_interval),
    "Catch-up block is in the skipped forced slot");
ok(@{$block2->transactions} && $block2->transactions->[0]->is_stake && @{$block2->transactions->[0]->in},
    "Catch-up block carries our stake");

block_hash("a3");
my $block3 = QBitcoin::Generate->generate(GENESIS_TIME + 3 * $forced_interval);
ok($block3, "Genesis catch-up continues with the next forced slot");
is(QBitcoin::Block->blockchain_height, 3, "Blockchain height 3");

done_testing();
