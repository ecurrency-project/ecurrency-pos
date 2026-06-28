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

done_testing();
