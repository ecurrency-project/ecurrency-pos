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

# 5b (robust): a best branch resting on an equivocated (banned) stake is invalid no
# matter how heavy it is. generate() must drop the best branch down to the banned block
# and rebuild on the last valid block. Here banned_height_in_best is mocked to point at
# a height; we check generate() unconfirms the branch down to it (the actual evidence
# detection/ban is covered by test/slashing.t).

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

# genesis a1, then a heavy peer block a2 becomes the tip.
send_blk(0, "a1", undef, 100, 100, 1);
send_blk(1, "a2", "a1",  900, 800, 1); # deliberately very heavy
is(QBitcoin::Block->best_block->hash, "a2", "heavy peer block a2 is the tip");

# a2 rests on an equivocated stake we hold evidence for (real unconfirm runs).
my $slash_module = Test::MockModule->new('QBitcoin::Slashing');
$slash_module->mock('banned_height_in_best', sub { 1 });

my @gen;
my $gen_module = Test::MockModule->new('QBitcoin::Generate');
$gen_module->mock('_generate', sub {
    my ($class, $ts, $h, $prev, $contest) = @_;
    push @gen, [ $ts, $h, $prev ? $prev->hash : undef, $contest ];
    return undef;
});

QBitcoin::Generate::Control->generate_level(undef);
my $slot = timeslot(time());
QBitcoin::Generate->generate($slot);

is(QBitcoin::Block->blockchain_height, 0, "the equivocated branch is dropped despite its higher weight");
isnt(QBitcoin::Block->best_block && QBitcoin::Block->best_block->hash, "a2", "a2 is no longer best");
ok(@gen >= 1, "a replacement block is generated");
is($gen[-1][2], "a1", "...rebuilt on the last valid block a1");
ok(!$gen[-1][3], "...using the mempool (so the slashing tx is pulled in)");

# Control: with no banned stake, a fresh heavy branch is kept (not dropped).
$slash_module->mock('banned_height_in_best', sub { undef });
send_blk(1, "a2", "a1", 900, 800, 1);
is(QBitcoin::Block->best_block->hash, "a2", "branch kept when there is no equivocated stake");
QBitcoin::Generate::Control->generate_level(undef);
QBitcoin::Generate->generate($slot);
is(QBitcoin::Block->blockchain_height, 1, "no drop without an equivocated stake");

done_testing();
