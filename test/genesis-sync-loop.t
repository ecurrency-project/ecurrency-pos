#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Block;
use QBitcoin::ProtocolState qw(blockchain_synced);
use Bitcoin::Serialized;

# Sync with a peer whose blockchain is built on a different genesis (GENESIS_HASH
# is not fixed: regtest or blockchain bootstrap). Locators from our best branch have
# no common blocks with the peer, so it answers getblks with its genesis block only.
# Once that genesis is cached in our block_pool, the node must request continuation
# of the alternative branch from it instead of looping on the same request.

#$config->{debug} = 1;

my @sent;
my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { push @sent, [ $_[1], $_[2] ]; 1 });
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });
$config->{regtest} = 1;

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => "127.0.0.1");
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
$connection->protocol->command = "block";
blockchain_synced(1);

# height, hash, prev_hash, weight
sub make_block {
    my ($height, $hash, $prev_hash, $weight) = @_;
    return QBitcoin::Block->new(
        time         => GENESIS_TIME + $height * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        weight       => $weight,
        merkle_root  => ZERO_HASH,
        transactions => [],
    );
}

sub send_block {
    my ($block) = @_;
    my $block_data = $block->serialize;
    block_hash($block->hash);
    $connection->protocol->cmd_block($block_data);
}

# Our chain
send_block(make_block(0, "a1", undef, 100));
send_block(make_block(1, "a2", "a1",  200));
my $a3 = make_block(2, "a3", "a2", 300);
send_block($a3);
is(QBitcoin::Block->best_block(2)->hash, "a3", "our branch loaded");

# Peer's genesis: cached as alternative branch, too low weight to switch
my $b1 = make_block(0, "b1", undef, 50);
send_block($b1);
ok(QBitcoin::Block->block_pool("b1"), "alternative genesis cached in block_pool");
is(QBitcoin::Block->best_block(0)->hash, "a1", "best branch not changed");

# Duplicate of a known non-genesis block: usual request_new_block, no continuation request
@sent = ();
send_block($a3);
is(scalar(grep { $_->[0] eq "getblks" } @sent), 0, "no getblks on duplicate of non-genesis block");

# Duplicate of the known alternative genesis (peer answers our getblks with it
# because none of our locators match its branch): request continuation from it
@sent = ();
send_block($b1);
my ($getblks) = grep { $_->[0] eq "getblks" } @sent;
ok($getblks, "getblks sent on duplicate of alternative genesis block") or diag explain \@sent;
if ($getblks) {
    my ($low_time, $locators) = unpack("Vv", substr($getblks->[1], 0, 6));
    is($low_time, timeslot($b1->time), "low_time is the genesis block timeslot");
    is($locators, 1, "single locator");
    is(substr($getblks->[1], 6), "b1", "locator is the alternative genesis block");
}

# The peer answers with continuation of its branch, node switches to it (reorg
# including the genesis block)
my $b2 = make_block(1, "b2", "b1", 350);
my $b3 = make_block(2, "b3", "b2", 450);
my $blocks_data = pack("C", 2);
for my $block ($b2, $b3) {
    block_hash($block->hash);
    $blocks_data .= $block->serialize;
}
$connection->protocol->command = "blocks";
$connection->protocol->cmd_blocks($blocks_data);
is(QBitcoin::Block->blockchain_height, 2, "blockchain height");
is(QBitcoin::Block->best_block(2)->hash, "b3", "switched to the branch with new genesis");
is(QBitcoin::Block->best_weight, 450, "best weight");
is(QBitcoin::Block->best_block(0)->hash, "b1", "new genesis in the best branch");

done_testing();
