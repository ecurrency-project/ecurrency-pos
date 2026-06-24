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
use QBitcoin::Slashing;
use QBitcoin::ProtocolState qw(blockchain_synced);

# 5b: when the best tip is a peer block whose stake is equivocated and we hold a
# slashing tx for it, generate() must unconfirm that tip and rebuild on its parent in
# the current timeslot using the mempool (so the slashing tx, whose UTXO is now free,
# is included). Here _generate and tip_slashing are mocked to check the decision wiring;
# the actual rebuild/reorg is exercised by the existing generate/receive machinery.

$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

blockchain_synced(1);

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => "127.0.0.1");
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
$connection->protocol->command = "block";

{
    package FakeStakeTx;
    sub is_stake       { 1 }
    sub confirm        { }
    sub unconfirm      { }
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

# genesis a1, then peer block a2 fills height 1 and becomes the tip.
send_blk(0, "a1", undef, 100, 100, 1);
send_blk(1, "a2", "a1",  200, 100, 1);
is(QBitcoin::Block->best_block->hash, "a2", "peer block a2 is the tip");

# a2's stake is equivocated: pretend we hold a slashing tx for it.
my $slash_module = Test::MockModule->new('QBitcoin::Slashing');
$slash_module->mock('tip_slashing', sub {
    my ($class, $tip) = @_;
    return $tip && $tip->hash eq "a2" ? bless({}, 'FakeSlashingTx') : undef;
});

# record unconfirm() and capture _generate()
my @unconf;
$block_module->mock('unconfirm', sub { my $self = shift; push @unconf, $self->hash; });
my @gen;
my $gen_module = Test::MockModule->new('QBitcoin::Generate');
$gen_module->mock('_generate', sub {
    my ($class, $ts, $h, $prev, $contest) = @_;
    push @gen, [ $ts, $h, $prev ? $prev->hash : undef, $contest ];
    return undef;
});

QBitcoin::Generate::Control->generate_level(undef); # ignore any contest flag from receiving a2
my $slot = timeslot(GENESIS_TIME + 1 * BLOCK_INTERVAL * FORCE_BLOCKS); # a2's slot
QBitcoin::Generate->generate($slot);

is(scalar @unconf, 1, "the peer tip was unconfirmed to make room for the slashing");
is($unconf[0], "a2", "...it is the equivocated tip a2");
is(scalar @gen, 1, "one block is generated");
is($gen[0][1], 1, "...at a2's height");
is($gen[0][2], "a1", "...on a2's parent a1");
ok(!$gen[0][3], "...using the mempool (not the branch-only contest path)");

# Control: with no slashing for the tip, the peer tip is NOT unconfirmed.
@unconf = ();
@gen = ();
$slash_module->mock('tip_slashing', sub { undef });
QBitcoin::Generate::Control->generate_level(undef);
QBitcoin::Generate->generate($slot);
is(scalar @unconf, 0, "no unconfirm when the tip has no slashing");

done_testing();
