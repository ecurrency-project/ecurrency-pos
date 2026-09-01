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

# receive() locates the last stake-carrying block of the old branch via
# transactions->[0]->is_stake. The mocked serializer carries only tx_hashes, not transaction
# objects, so a received block has no transactions; mark "staked" blocks by injecting a stub
# stake tx into the stored block after it is received. receive() only calls is_stake on it
# (for the contest reference) and confirm/unconfirm on a reorg.
{
    package FakeStakeTx;
    sub is_stake      { 1 }
    sub confirm       { }
    sub unconfirm     { }
    sub del_from_block { }
}
my $stake_tx = bless {}, 'FakeStakeTx';

sub send_blk {
    my ($height, $hash, $prev_hash, $weight, $self_weight, $staked) = @_;
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
    if ($staked) {
        my $stored = QBitcoin::Block->best_block($height);
        $stored->transactions([ $stake_tx ]) if $stored && $stored->hash eq $hash;
    }
}

# a1 is the genesis-level block; a2 fills the next (previously empty) slot on top of it.
# Both carry stake (staked => 1), so they anchor the contest reference.
send_blk(0, "a1", undef, 100, 100, 1);
send_blk(1, "a2", "a1",  200, 100, 1);

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
# We aim for the latest past slot (more stake weight), but it is capped at the last slot of
# prev a1's forced-block window - a later slot would skip a forced block and be invalid.
# Here a1 sits at the genesis slot so the cap is the next forced boundary (== a2's slot).
is($gen[0][0], GENESIS_TIME + FORCE_BLOCKS * BLOCK_INTERVAL, "...at prev's forced-block boundary, not a far-future slot");
is($gen[0][1], 1, "...at a2's height");
is($gen[0][2], "a1", "...on a1, the block before the filled slot");
ok($gen[0][3], "...using only the contested branch's transactions");
is(QBitcoin::Generate::Control->generate_level, undef, "generate_level cleared after generate()");

# Switching to b2, which is in the same slot as our last staked block a2 (not a later one),
# is a reorg we cannot outweigh with our own block for that slot: generate_level must stay
# cleared.
send_blk(1, "b2", "a1", 250, 150, 1);
is(QBitcoin::Block->best_block->hash, "b2", "Heavier b2 became best");
is(QBitcoin::Generate::Control->generate_level, undef, "generate_level cleared when block is not in a later slot than our last staked block");

# The bug this guards against: our own tip can be an EMPTY/forced block in a later slot (our
# stake coin was too young to add weight). A peer block that fills the slot of our last
# *staked* block with real stake must still be contested, even though it is not in a slot
# later than our empty tip. e3 is our empty tip on top of b2 (self_weight 0, no stake weight).
send_blk(2, "e3", "b2", 250, 0);
is(QBitcoin::Block->best_block->hash, "e3", "Empty e3 extends the branch and becomes best");
QBitcoin::Generate::Control->generate_level(undef); # ignore the flag from installing e3
# p3: heavier peer block at e3's height, carrying real stake. The old-tip-slot rule would
# skip it (not later than the empty tip e3); the last-staked-slot rule (b2) contests it.
send_blk(2, "p3", "b2", 310, 60, 1);
is(QBitcoin::Block->best_block->hash, "p3", "Heavier p3 became best");
is(QBitcoin::Generate::Control->generate_level, 2, "generate_level flags p3: empty tip e3 must not raise the contest bar");
# p3's pending target would keep the lower level through the c3 receive below (see the
# no-displace test at the end); clear it as if generate() had consumed it.
QBitcoin::Generate::Control->generate_level(undef);

# Current-slot contest: a peer block that fills the CURRENT slot at our tip height cannot be
# beaten by the normal generation path - that would build a stakeless block on top of it
# (the contested branch already consumed the slot's fee tx, so reward would be 0). contest_level
# must instead build our competing block directly in the current slot, at the contested height,
# on its parent, reusing only the contested branch's transactions (so the fee tx is available
# and our stake applies) - and signal generate() not to build another block on top.
send_blk(3, "c3", "p3", 400, 90, 1);
is(QBitcoin::Block->best_block->hash, "c3", "Heavier c3 became best");
is(QBitcoin::Generate::Control->generate_level, 3, "generate_level flags c3 at our tip height");
my $c3_slot = GENESIS_TIME + 3 * BLOCK_INTERVAL * FORCE_BLOCKS; # c3's own slot, used as the current slot
@gen = ();
QBitcoin::Generate->generate($c3_slot);
is(scalar(@gen), 1, "current-slot contest builds exactly one block (no block on top)");
is($gen[0][0], $c3_slot, "...in the current slot itself, not the previous one (max stake weight)");
is($gen[0][1], 3, "...at the contested height");
is($gen[0][2], "p3", "...on p3, the block before the contested one");
ok($gen[0][3], "...using only the contested branch's transactions (so its fee tx lets us stake)");
is(QBitcoin::Generate::Control->generate_level, undef, "generate_level cleared after current-slot contest");

# A pending target must never expire at the slot border: a cheap block signed in the
# last milliseconds of its slot (hoping to be accepted but never contested) still gets
# contested right after the border - through the past-slot path, with the current-slot
# block built on top. Only an actual contest attempt consumes the target.
QBitcoin::Generate::Control->generate_level(3);
@gen = ();
QBitcoin::Generate->generate($c3_slot + BLOCK_INTERVAL);
is(scalar(@gen), 2, "target pending from the previous slot is still contested after the border");
is($gen[0][0], $c3_slot, "...in the contested block's slot (the latest allowed past slot)");
is($gen[0][1], 3, "...at the contested height");
is($gen[0][2], "p3", "...on p3, the block before the contested one");
ok($gen[0][3], "...using only the contested branch's transactions");
is($gen[1][1], 4, "...and the current-slot block is built on top");
is(QBitcoin::Generate::Control->generate_level, undef, "target consumed by the late contest");

# A block received on top must not displace a still-pending lower contest target: the flag
# is only consumed by the next generate() pass, which may be a randomized in-slot delay
# away, and the pending (lower) block is the one worth contesting. This is how a
# hole-filler escaped its contest on 2026-08-26 (bb4caa7b h1855673: the stakeless append
# 001d7b20 arriving 100ms later moved the target to h1855674, and the contest was wasted).
send_blk(4, "d4", "c3", 500, 90, 1);
is(QBitcoin::Block->best_block->hash, "d4", "d4 became best");
is(QBitcoin::Generate::Control->generate_level, 4, "append flags d4's height");
send_blk(5, "e5", "d4", 600, 90, 1);
is(QBitcoin::Block->best_block->hash, "e5", "e5 became best");
is(QBitcoin::Generate::Control->generate_level, 4, "pending lower contest target survives the e5 append");
# ...while a LOWER new target still replaces a higher pending one
QBitcoin::Generate::Control->generate_level(undef);
QBitcoin::Generate::Control->generate_level(7);
send_blk(6, "f6", "e5", 700, 90, 1);
is(QBitcoin::Generate::Control->generate_level, 6, "lower new contest target replaces a higher pending one");

# A pending contest of a peer block in a PAST slot is produced immediately: the main loop
# consults contest_pending_past() to skip the randomized in-slot delay for it (the delay
# protects our own current-slot stake commitment, which a past-slot contest does not touch).
# A current-slot target keeps the delay.
my $f6_slot = GENESIS_TIME + 6 * BLOCK_INTERVAL * FORCE_BLOCKS;
ok(QBitcoin::Generate->contest_pending_past($f6_slot + BLOCK_INTERVAL),
    "pending past-slot contest target skips the generation delay");
ok(!QBitcoin::Generate->contest_pending_past($f6_slot),
    "current-slot contest target keeps the delay");
{
    my $f6 = QBitcoin::Block->best_block(6);
    my $connection_saved = $f6->received_from;
    $f6->received_from(undef);
    ok(!QBitcoin::Generate->contest_pending_past($f6_slot + BLOCK_INTERVAL),
        "our own block at the target height is not contested - no bypass");
    $f6->received_from($connection_saved);
}
QBitcoin::Generate::Control->generate_level(undef);
QBitcoin::Generate::Control->generate_level(42);
ok(!QBitcoin::Generate->contest_pending_past($f6_slot + BLOCK_INTERVAL),
    "target height without a best block - no bypass");
QBitcoin::Generate::Control->generate_level(undef);
ok(!QBitcoin::Generate->contest_pending_past($f6_slot + BLOCK_INTERVAL),
    "no pending target - no bypass");

# Installing a contest target must also reopen the generation gate (generate_new): when
# the displacing block is in the CURRENT slot at the same height, neither of receive()'s
# other generate_new() triggers fires (the branch does not start in a past slot, and
# sibling parents weigh the same), so with this slot's generation already done the
# pending target would wait for the next slot (seen live 2026-09-01 h1889456: "Contest
# block e1ac73d1 ... from past slot" right after the border instead of an in-slot
# contest). Wall-clock reads inside receive() are mocked so the incoming block lands
# "in its own slot".
my $g7_slot = GENESIS_TIME + 7 * BLOCK_INTERVAL * FORCE_BLOCKS;
my $o8_slot = GENESIS_TIME + 8 * BLOCK_INTERVAL * FORCE_BLOCKS;
my $fake_now_slot;
my $receive_module = Test::MockModule->new('QBitcoin::Block::Receive');
$receive_module->mock('timeslot', sub {
    my ($time) = @_;
    # block times keep the real formula; only wall-clock time() reads get the fake slot
    return $fake_now_slot if defined($fake_now_slot) && $time > $o8_slot;
    my $t = int($time);
    return $t - $t % BLOCK_INTERVAL;
});
$fake_now_slot = $g7_slot; # receive g7 "in its own slot"
QBitcoin::Generate::Control->generate_level(undef);
QBitcoin::Generate::Control->generated_time($g7_slot); # this slot's generation already ran
send_blk(7, "g7", "f6", 800, 90, 1);
is(QBitcoin::Block->best_block->hash, "g7", "current-slot block g7 became best");
is(QBitcoin::Generate::Control->generate_level, 7, "current-slot switch installs the contest target");
ok(!defined(QBitcoin::Generate::Control->generated_time),
    "...and reopens the generation gate so the contest happens within the slot");

# ...while a switch that installs no target (the displaced tip carried stake in the same
# slot - a plain weight race already lost) must NOT reopen the gate
QBitcoin::Generate::Control->generate_level(undef);
QBitcoin::Generate::Control->generated_time($g7_slot);
send_blk(7, "h7", "f6", 850, 140, 1);
is(QBitcoin::Block->best_block->hash, "h7", "heavier sibling h7 displaced g7");
is(QBitcoin::Generate::Control->generate_level, undef,
    "same-slot displacement of a same-slot staked tip installs no target");
is(QBitcoin::Generate::Control->generated_time, $g7_slot, "...and the gate stays closed");

# Our OWN block also flags its height structurally (an append walks nothing, so the
# last-stake bar is -1), but its receive() runs right after _generate closed the gate:
# it must neither install a self-target (contesting applies to peer blocks only) nor
# reopen the gate after every block we produce.
$fake_now_slot = $o8_slot;
QBitcoin::Generate::Control->generated_time($o8_slot);
my $own = QBitcoin::Block->new(
    time         => $o8_slot,
    height       => 8,
    hash         => "o8",
    prev_hash    => "h7",
    prev_block   => QBitcoin::Block->best_block(7),
    weight       => 950,
    self_weight  => 100,
    merkle_root  => ZERO_HASH,
    transactions => [],
);
block_hash($own->hash);
is($own->receive(), 0, "own block accepted");
is(QBitcoin::Block->best_block->hash, "o8", "own block became best");
is(QBitcoin::Generate::Control->generate_level, undef, "own block installs no contest target for itself");
is(QBitcoin::Generate::Control->generated_time, $o8_slot,
    "...and leaves the gate closed after our own generation");
$receive_module->unmock('timeslot');
QBitcoin::Generate::Control->generated_time(undef);

done_testing();
