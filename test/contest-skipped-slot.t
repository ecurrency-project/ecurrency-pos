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
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Block;
use QBitcoin::Generate;
use QBitcoin::Generate::Control;
use QBitcoin::ProtocolState qw(blockchain_synced);

# When the best branch is switched to a block that a peer produced for a slot that was
# empty in our branch, receive() must flag that block's height via generate_level so the
# next generate() pass tries to contest it on weight (building at the block's own past
# slot, not the current one). receive() only does the structural hole detection; the
# time-based decision lives in QBitcoin::Generate::contest_level().

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

# a1 is the genesis-level block; a2 fills the next (previously empty) slot on top of it.
send_blk(0, "a1", undef, 100, 100);
send_blk(1, "a2", "a1",  200, 100);

is(QBitcoin::Block->best_block->hash, "a2", "Peer block a2 became best");
is(QBitcoin::Generate::Control->generate_level, 1, "generate_level flags a2's height (the filled slot)");

# contest_level() must build in the previous slot (not a2's own slot), on a1, at a2's
# height, and using only the contested branch's transactions.
my @gen;
my $generate_module = Test::MockModule->new('QBitcoin::Generate');
$generate_module->mock('_generate', sub {
    my ($class, $timeslot, $height, $prev_block, $contest) = @_;
    push @gen, [ $timeslot, $height, $prev_block ? $prev_block->hash : undef, $contest ];
    return undef;
});
my $now_slot = timeslot(time());
QBitcoin::Generate::Control->generate_level(1);
QBitcoin::Generate->generate($now_slot);
is(scalar(@gen), 2, "generate builds two blocks");
is($gen[0][0], $now_slot - BLOCK_INTERVAL, "...in the previous slot (more stake weight), not a2's slot");
is($gen[0][1], 1, "...at a2's height");
is($gen[0][2], "a1", "...on a1, the block before the filled slot");
ok($gen[0][3], "...using only the contested branch's transactions");
is(QBitcoin::Generate::Control->generate_level, undef, "generate_level cleared after generate()");

# Switching to b2, which is in the same slot as our tip a2 (not a later one), is a reorg
# we cannot outweigh with our own block for that slot: generate_level must be cleared.
send_blk(1, "b2", "a1", 250, 150);
is(QBitcoin::Block->best_block->hash, "b2", "Heavier b2 became best");
is(QBitcoin::Generate::Control->generate_level, undef, "generate_level cleared when block is not in a later slot than our tip");

done_testing();
