#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(make_block send_block send_tx send_raw_tx $connection);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;

# Reproduce the crash "Attempt to override already loaded txo"
#
# Scenario:
#   - block b3 is pending on unknown ancestor b2, its stake tx A is pending
#     on unknown input X
#   - block c4 is pending on b3, its stake tx B spends A:0 while A is pending
#     (input_detached path)
#   - tx X arrives, the chain X -> A -> B resolves, blocks b3/c4 get their
#     txs but remain pending on b2
#   - b2 arrives and fails validation => the whole pending branch is dropped
#   - the peer reconnects and sends the same branch again; when tx A is
#     received again its output A:0 must be gone from the %TXO cache

#$config->{debug} = 1;
$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

blockchain_synced(1);

# Best branch: a0 <- a1
my $start_tx = send_tx();
send_block(0, "a0", undef, 50, $start_tx);
send_block(1, "a1", "a0", 52, send_tx(0, $start_tx));

# Competing branch txs: X (coinbase) <- A (stake) <- B (stake)
my $tx_x = make_tx(undef, 0);
my $tx_a = make_tx($tx_x, -1);
my $tx_b = make_tx($tx_a, -1);

# Block b3 arrives: unknown ancestor b2, stake tx A unknown => both pending
send_block(3, "b3", "b2", 70, $tx_a);
# tx A arrives: its input X:0 is unknown => A goes to PENDING_TX_INPUT,
# outputs of A are saved to %TXO
send_raw_tx($tx_a);
ok(QBitcoin::Transaction->has_pending($tx_a->hash), "tx A is pending on unknown input");
# Block c4 arrives: pending ancestor b3, stake tx B unknown => pending
send_block(4, "c4", "b3", 80, $tx_b);
# tx B arrives: its input A:0 is found in %TXO but tx A is pending
# => B saved as dependent on pending A (input_detached)
send_raw_tx($tx_b);
# tx X arrives and resolves the chain: X -> A -> B are processed,
# blocks b3 and c4 receive their pending txs but remain pending on b2
send_raw_tx($tx_x);
ok(!QBitcoin::Transaction->has_pending($tx_a->hash), "tx A resolved");
ok(defined QBitcoin::Transaction->get($tx_a->hash), "tx A in mempool");
ok(defined QBitcoin::Transaction->get($tx_b->hash), "tx B in mempool");

# Invalid block b2 arrives: time is not aligned to a forced-block slot,
# validation fails => free() => the pending branch b3 <- c4 is dropped
# together with its stake transactions
{
    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + 2 * BLOCK_INTERVAL * FORCE_BLOCKS + BLOCK_INTERVAL,
        hash         => "b2",
        prev_hash    => "a1",
        transactions => [],
        weight       => 60,
    );
    $block->merkle_root = $block->calculate_merkle_root();
    my $block_data = $block->serialize;
    QBitcoin::Test::BlockSerialize::block_hash($block->hash);
    $connection->protocol->command("block");
    is($connection->protocol->cmd_block($block_data), -1, "block b2 rejected as invalid");
}

is(QBitcoin::Transaction->get($tx_a->hash), undef, "tx A dropped from mempool");
is(QBitcoin::Transaction->get($tx_b->hash), undef, "tx B dropped from mempool");
is(QBitcoin::TXO->get({ tx_out => $tx_a->hash, num => 0 }), undef, "txo A:0 released from TXO cache");
# tx X is a plain mempool tx not related to the dropped branch, it stays cached
ok(defined QBitcoin::Transaction->get($tx_x->hash), "tx X stays in mempool");

# The peer re-sends the same branch after reconnect: receiving tx A again
# must not die with "Attempt to override already loaded txo"
my $res = eval {
    send_block(3, "b3", "b2", 70, $tx_a);
    $connection->protocol->command("tx");
    $connection->protocol->cmd_tx($tx_a->serialize . "\x00"x16);
};
is($@, '', "re-receiving tx A does not crash");
is($res, 0, "tx A accepted as pending again") if !$@;

done_testing();
