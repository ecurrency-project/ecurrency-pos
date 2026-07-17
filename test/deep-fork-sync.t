#! /usr/bin/env perl
use warnings;
use strict;

# Synchronization of a fork deeper than MAX_PENDING_BLOCKS in "synced" (non-batch) mode.
# The node walks the peer branch backwards one block at a time; the pending pool keeps
# only the last MAX_PENDING_BLOCKS received blocks, so the top of the branch is dropped
# before the bottom connects. The sync must still converge as a ratchet: each pass
# connects the assembled bottom part of the branch, and the next walk continues from
# the connected part ("already in block_pool" / "already pending" must not stall it).
# This is the scenario of a genesis node (blockchain_synced is never reset) which was
# generating its own blocks while disconnected from the network for a long time.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Crypto qw(hash160);
use Bitcoin::Serialized;

$config->{regtest} = 1;

my @sent;
my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { push @sent, [ $_[1], $_[2], $_[0] ]; 1 }); # [ command, data, sender ]

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => '127.0.0.1');
my $connection = QBitcoin::Connection->new(peer => $peer, state => STATE_CONNECTED);
my $protocol = $connection->protocol;

my %tx_by_hash;
my $tx_value = 10;

sub make_block {
    my ($height, $hash, $prev_hash, $weight, $tx_num) = @_;

    my @tx;
    foreach (1 .. ($tx_num // 0)) {
        my $tx = QBitcoin::Transaction->new(
            out           => [ QBitcoin::TXO->new_txo( value => $tx_value, scripthash => hash160("txo_$hash"), data => "" ) ],
            in            => [],
            coins_created => $tx_value,
            tx_type       => TX_TYPE_COINBASE,
        );
        $tx_value += 10;
        $tx->calculate_hash;
        $tx_by_hash{$tx->hash} = $tx;
        push @tx, $tx;
    }
    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + $height * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => \@tx,
        weight       => $weight,
    );
    $block->merkle_root = $block->calculate_merkle_root();
    return $block;
}

sub send_block {
    my $block = make_block(@_);
    my $block_data = $block->serialize;
    block_hash($block->hash);
    $protocol->cmd_block($block_data);
    return $block;
}

# Respond to "sendtx" requests like a remote peer: feed the requested transactions.
# Each fed transaction may complete a pending block, which requests transactions of
# the next pending block, and so on (the ascent of the assembled branch).
sub feed_requested_tx {
    my $fed = 0;
    while (my ($req) = grep { $_->[0] eq "sendtx" } @sent) {
        @sent = grep { $_ != $req } @sent;
        my $tx = delete $tx_by_hash{$req->[1]}
            or next;
        $protocol->cmd_tx($tx->serialize . "\x00"x16);
        $fed++;
    }
    return $fed;
}

# Own chain: a0 .. a9
send_block($_, "a$_", $_ ? "a" . ($_ - 1) : undef, ($_ + 1) * 100, 0) foreach 0 .. 9;
blockchain_synced(1);
is(QBitcoin::Block->blockchain_height, 9,    "own chain height");
is(QBitcoin::Block->best_block->hash,  "a9", "own chain best block");

# Peer branch: fork at a0 (deeper than INCORE_LEVELS), c1 .. cD, D > MAX_PENDING_BLOCKS,
# each block adds more weight than a block of our own chain
my $depth = MAX_PENDING_BLOCKS + 44;

# Pass 1: walk the branch backwards from the top, as the sendblock chain does.
# The pending pool overflows and drops the top blocks, the bottom connects to a0
# and the assembled part of the branch reorgs our chain.
@sent = ();
foreach my $h (reverse 1 .. $depth) {
    send_block($h, "c$h", $h > 1 ? "c" . ($h - 1) : "a0", $h * 1000, 0);
}
my $pass1_height = QBitcoin::Block->blockchain_height;
ok($pass1_height > 9, "pass 1 connected the bottom of the branch and reorged (height $pass1_height)");
ok($pass1_height < $depth, "the top of the branch was dropped by the pending pool overflow");
is(QBitcoin::Block->best_block->hash, "c$pass1_height", "pass 1 best block on the peer branch");
ok(!(grep { $_->[0] eq "getblks" } @sent), "no batch requests in synced mode");

# Pass 2: the walk restarts from the top block of the peer branch; when it reaches
# the already connected part, the pending chain connects to it and the sync completes
foreach my $h (reverse $pass1_height + 1 .. $depth) {
    send_block($h, "c$h", "c" . ($h - 1), $h * 1000, 0);
}
is(QBitcoin::Block->blockchain_height,  $depth,    "pass 2 completed the branch");
is(QBitcoin::Block->best_block->hash,   "c$depth", "best block is the branch top");
ok(blockchain_synced(), "node stays in synced (non-batch) mode");
ok(!(grep { $_->[0] eq "getblks" } @sent), "still no batch requests");

# A branch is downloaded via a single peer; a duplicate of a pending block received
# from another peer must not duplicate the download while the branch owner is syncing,
# and must take the branch over when the owner is not driving it anymore
my $peer2 = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => '127.0.0.2');
my $connection2 = QBitcoin::Connection->new(peer => $peer2, state => STATE_CONNECTED);
my $protocol2 = $connection2->protocol;

@sent = ();
my $d_top = $depth + 10;
foreach my $h (reverse $depth + 5 .. $d_top) { # pending chain with unknown ancestors
    send_block($h, "d$h", "d" . ($h - 1), $h * 1000 + 500, 0);
}
is($sent[-1][0], "sendblock", "walking the new branch");
is($sent[-1][1], "d" . ($depth + 4), "requested the deepest unknown ancestor");
ok($protocol->syncing, "branch owner is in syncing state");

sub send_dup { # duplicate of the pending branch top via the second peer
    my $block = make_block($d_top, "d$d_top", "d" . ($d_top - 1), $d_top * 1000 + 500, 0);
    block_hash($block->hash);
    $protocol2->cmd_block($block->serialize);
}
@sent = ();
send_dup();
ok(!(grep { $_->[0] eq "sendblock" } @sent), "no duplicate requests while the branch owner is syncing");
ok(!$protocol2->syncing, "the second peer stood down (syncing reset)");

$protocol->syncing(0); # the owner stalled / stood down / was reset
@sent = ();
send_dup();
is($sent[-1][0], "sendblock", "the branch was taken over by the second peer");
is($sent[-1][1], "d" . ($depth + 4), "takeover continues from the deepest unknown ancestor");
ok($protocol2->syncing, "the second peer is the branch driver now");

# Sweeping the pending blocks of a peer (disconnect, empty-queue ping detector) must
# not drop its blocks stacked on a branch downloaded via another peer, only the blocks
# rooted in this peer's own chains
my $block = make_block($d_top + 1, "d" . ($d_top + 1), "d$d_top", ($d_top + 1) * 1000 + 500, 0);
block_hash($block->hash);
$protocol2->cmd_block($block->serialize); # new block on top of the pending branch of peer 1
$block = make_block($d_top + 1, "f" . ($d_top + 1), "f$d_top", ($d_top + 1) * 1000 + 600, 0);
block_hash($block->hash);
$protocol2->cmd_block($block->serialize); # floating block rooted in peer 2 itself
ok(QBitcoin::Block->is_pending("d" . ($d_top + 1)), "stacked block is pending");
ok(QBitcoin::Block->is_pending("f" . ($d_top + 1)), "floating block is pending");
QBitcoin::Block->drop_all_pending($protocol2);
ok(QBitcoin::Block->is_pending("d" . ($d_top + 1)), "stacked block survived the sweep of its peer");
ok(!QBitcoin::Block->is_pending("f" . ($d_top + 1)), "floating block of the same peer was dropped");

# Transactions of blocks with unknown ancestors are not requested during the walk
# (they cannot be validated before their ancestor blocks are received); they are
# requested when the block's ancestor chain connects to known blocks
%tx_by_hash = ();
@sent = ();
my $e_top = $depth + 5;
foreach my $h (reverse $depth + 2 .. $e_top) { # e-branch forks at c$depth, with transactions
    send_block($h, "e$h", "e" . ($h - 1), $h * 2000, 1);
}
ok(!(grep { $_->[0] eq "sendtx" } @sent), "no tx requests for blocks with unknown ancestors during the walk");
# the bottom block has a known ancestor: its transactions are requested at once,
# and after it connects, transactions of each next pending block are requested in turn
send_block($depth + 1, "e" . ($depth + 1), "c$depth", ($depth + 1) * 2000, 1);
ok((grep { $_->[0] eq "sendtx" } @sent), "transactions of the bottom block with known ancestor requested");
while (feed_requested_tx()) {} # serve tx requests until the ascent completes
is(QBitcoin::Block->blockchain_height, $e_top,    "branch with transactions fully connected");
is(QBitcoin::Block->best_block->hash,  "e$e_top", "best block is the top of the tx branch");

# Deferred transactions of a pending block are requested via the peer whose data
# connected the chain (the current driver), not via the peer which delivered the
# pending block itself (it may be gone by that time)
%tx_by_hash = ();
@sent = ();
my $g_top = $e_top + 2;
send_block($g_top, "g$g_top", "g" . ($g_top - 1), $g_top * 3000, 1); # via peer 1, unknown ancestor
ok(QBitcoin::Block->is_pending("g$g_top"), "top block is pending");
ok(!(grep { $_->[0] eq "sendtx" } @sent), "its transactions are not requested yet");
my $g_block = make_block($g_top - 1, "g" . ($g_top - 1), "e$e_top", ($g_top - 1) * 3000, 0);
block_hash($g_block->hash);
$protocol2->cmd_block($g_block->serialize); # the connecting block arrives from the second peer
my ($txreq) = grep { $_->[0] eq "sendtx" } @sent;
ok($txreq, "transactions of the pending block requested when its ancestor connected");
is($txreq->[2], $protocol2, "requested via the peer which connected the chain");
while (feed_requested_tx()) {}
is(QBitcoin::Block->best_block->hash, "g$g_top", "the branch completed");

done_testing();
