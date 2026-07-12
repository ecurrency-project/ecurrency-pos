#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Block;
use QBitcoin::ProtocolState qw(blockchain_synced);

# Reproduce the h1504505/h1504506 reorg churn from qecr-2026-06-28.log and check that the
# prev_block->next_block linkage of the surviving fork block points at the final best child
# (not a freed sibling / undef). The contest's choose_for_block branch-pull walks
# $prev_block->next_block to reuse the contested block's txs; a broken pointer would make it
# pull nothing.
#
# Real sequence (heights relabelled h2 = 1504505, h3 = 1504506):
#   P (=821c2929) -> A (=c46a00ab) best
#   B (=fd2ef6e6) replaces A           (A freed)
#   D (=d73e66fb) replaces B           (B freed)
#   X (=72da10d0, child of B) wins      (B re-added)
#   Y (=b1c91a90, child of B) replaces X
# Expect B->next_block == Y.

$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

blockchain_synced(1);

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => "127.0.0.1");
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
$connection->protocol->command = "block";

sub send_blk {
    my ($height, $hash, $prev_hash, $weight, $self_weight) = @_;
    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + $height * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        weight       => $weight,
        self_weight  => $self_weight,
        merkle_root  => ZERO_HASH,
        transactions => [],
    );
    block_hash($block->hash);
    $connection->protocol->cmd_block($block->serialize);
}

send_blk(0, "g", undef, 100, 100);
send_blk(1, "P", "g",   200, 100);
send_blk(2, "A", "P",   300, 100);
is(QBitcoin::Block->best_block->hash, "A", "A best at h2");
send_blk(2, "B", "P",   350, 150);
is(QBitcoin::Block->best_block->hash, "B", "B replaces A at h2");
send_blk(2, "D", "P",   360, 160);
is(QBitcoin::Block->best_block->hash, "D", "D replaces B at h2 (B now freed)");

# X is a child of B (now freed). It arrives first (pending on unknown ancestor B), then B is
# re-sent so the B->X branch connects and outweighs D.
send_blk(3, "X", "B", 500, 140);
send_blk(2, "B", "P", 350, 150);
is(QBitcoin::Block->best_block->hash, "X", "B+X branch wins, X best at h3");
is(QBitcoin::Block->best_block(2)->hash, "B", "B re-added as best at h2");

send_blk(3, "Y", "B", 600, 250);
is(QBitcoin::Block->best_block->hash, "Y", "Y replaces X at h3");
is(QBitcoin::Block->best_block(2)->hash, "B", "B still best at h2");

my $B = QBitcoin::Block->best_block(2);
ok($B->next_block, "B->next_block is set (chain not broken)");
is($B->next_block && $B->next_block->hash, "Y", "B->next_block points at the final best child Y");

done_testing();
