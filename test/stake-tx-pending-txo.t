#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Test::Send qw($connection);
use QBitcoin::Test::MakeTx;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Transaction;
use QBitcoin::Protocol;
use QBitcoin::Generate;

# Demonstrate the "Attempt to override already loaded txo" crash in generate().
#
# Scenario:
#   A stake tx S is received via cmd_tx while its input (coinbase) is unknown.
#   S goes to PENDING_TX_INPUT; its output S:0 is saved to %TXO.
#   make_stake_tx is mocked to return the same S, bypassing the need for real
#   confirmed staking UTXOs.  generate() then hits the guard that should skip
#   block generation.
#
# Without the fix (original branch):
#   The guard only calls check_by_hash(), which returns false (S is not in
#   %TRANSACTION or the DB).  generate() proceeds to save_all(), which tries
#   to save S:0 into %TXO — but the old S:0 is still alive (held by S in
#   PENDING_TX_INPUT) => die "Attempt to override already loaded txo" is
#   caught by eval => ok(!$@) reports FAIL.
#
# With the fix (patched branch):
#   The guard also calls has_pending(), which returns true.  generate()
#   returns early without calling save_all() => no exception
#   => ok(!$@) reports PASS.

#$config->{debug} = 1;
$config->{regtest} = 1;
$config->{genesis} = 1;
$config->{genesis_reward} = GENESIS_REWARD;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });

# Build the stake tx whose input will remain unknown.
my $coinbase  = make_tx(undef, 0);       # TX_TYPE_COINBASE  (never sent)
my $stake_tx  = make_tx($coinbase, -2);  # TX_TYPE_STAKE, fee < 0

# generate() reads $stake_tx->size after the first make_stake_tx call.
$stake_tx->size = length($stake_tx->serialize);

# Receive only the stake tx.  Its input (coinbase:0) is absent from %TXO
# and the DB, so load_txo puts the tx into PENDING_TX_INPUT and saves its
# output S:0 to %TXO.
$connection->protocol->command("tx");
$connection->protocol->cmd_tx($stake_tx->serialize . "\x00"x16);

ok(QBitcoin::Transaction->has_pending($stake_tx->hash),
    "Stake tx is in PENDING_TX_INPUT (coinbase input unknown)");

# Mock make_stake_tx so that generate() receives the already-pending tx.
# Both the size-probe call and the real call return the same object.
my $generate_module = Test::MockModule->new('QBitcoin::Generate');
$generate_module->mock('make_stake_tx', sub { $stake_tx });

# Run generate() inside eval so a crash becomes a test failure instead of
# killing the whole process.
block_hash("gen0");
eval { QBitcoin::Generate->generate(GENESIS_TIME) };

ok(!$@, "generate() does not crash when stake tx is already pending")
    or diag("Got exception: $@");

done_testing();
