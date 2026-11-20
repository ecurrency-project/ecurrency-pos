#! /usr/bin/env perl
use warnings;
use strict;

# Batch synchronization ("blocks" message): the transactions of all blocks of the batch
# are requested at once, when the batch is received. A block of the batch waits for its
# ancestor from the same batch; when the ancestor connects, the transactions of the block
# must not be requested again: the duplicates are useless and the response to the next
# batch request is queued behind them on the remote side.

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

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => IPV6_V4_PREFIX . pack("C4", 127, 0, 0, 1));
my $connection = QBitcoin::Connection->new(peer => $peer, state => STATE_CONNECTED);
my $protocol = $connection->protocol;
my $peer2 = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => IPV6_V4_PREFIX . pack("C4", 127, 0, 0, 2));
my $connection2 = QBitcoin::Connection->new(peer => $peer2, state => STATE_CONNECTED);
my $protocol2 = $connection2->protocol;

my %tx_by_hash;
my $tx_value = 10;

sub make_block {
    my ($height, $hash, $prev_hash, $weight) = @_;

    my $tx = QBitcoin::Transaction->new(
        out           => [ QBitcoin::TXO->new_txo( value => $tx_value, scripthash => hash160("txo_$hash"), data => "" ) ],
        in            => [],
        coins_created => $tx_value,
        tx_type       => TX_TYPE_COINBASE,
    );
    $tx_value += 10;
    $tx->calculate_hash;
    $tx_by_hash{$tx->hash} = $tx;
    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + $height * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => [ $tx ],
        weight       => $weight,
    );
    $block->merkle_root = $block->calculate_merkle_root();
    return $block;
}

# Batch of blocks $from .. $to of the chain "b", each block with one transaction unknown to us
sub send_blocks {
    my ($via, $from, $to) = @_;
    my @blocks = map { make_block($_, "b$_", $_ ? "b" . ($_ - 1) : undef, ($_ + 1) * 100) } $from .. $to;
    block_hash($_->hash) foreach @blocks;
    $via->command("blocks");
    return $via->cmd_blocks(pack("C", scalar(@blocks)) . join("", map { $_->serialize } @blocks));
}

# Respond to "sendtx" requests like a remote peer, in the order of the requests;
# returns the number of the requests for each transaction
sub feed_requested_tx {
    my ($via) = @_;
    my %requested;
    while (my ($req) = grep { $_->[0] eq "sendtx" } @sent) {
        @sent = grep { $_ != $req } @sent;
        $requested{$req->[1]}++;
        my $tx = delete $tx_by_hash{$req->[1]}
            or next;
        $via->command("tx");
        $via->cmd_tx($tx->serialize . "\x00"x16);
    }
    return \%requested;
}

# Genesis block is received by the "block" message
my $genesis = make_block(0, "b0", undef, 100);
block_hash($genesis->hash);
$protocol->command("block");
$protocol->cmd_block($genesis->serialize);
feed_requested_tx($protocol);
is(QBitcoin::Block->blockchain_height, 0, "genesis block received");

my $batch = 20;
is(send_blocks($protocol, 1, $batch), 0, "batch of blocks received");
is(scalar(grep { $_->[0] eq "sendtx" } @sent), $batch, "transactions of all blocks of the batch requested at once");
ok(!(grep { $_->[0] eq "getblks" } @sent), "next batch is not requested until this one is processed");

# A new block announced by the same peer in the middle of the batch must not cause
# a request of the same batch again; the next batch is requested when this one is processed
my $announced_weight = ($batch + 10) * 100;
$protocol->command("ihave");
$protocol->cmd_ihave(pack("VQ<a32", GENESIS_TIME, $announced_weight, "n" x 32));
ok(!blockchain_synced(), "blockchain is not synced");
ok(!(grep { $_->[0] eq "getblks" } @sent), "no batch request on the announce in the middle of the batch");
is($protocol->has_weight, $announced_weight, "the announced weight is remembered");
my $requested = feed_requested_tx($protocol);
is(QBitcoin::Block->blockchain_height, $batch, "the batch is connected");
is(scalar(keys %$requested), $batch, "all transactions were requested");
is(scalar(grep { $_ != 1 } values %$requested), 0, "each transaction was requested once");
is(scalar(grep { $_->[0] eq "getblks" } @sent), 1, "next batch requested when the batch is processed");

# The request is repeated via the current driver of the branch if the peer which was
# asked for the transactions is gone. Its blocks survive the disconnect only if they
# are stacked on a pending branch received from another peer.
@sent = ();
is(send_blocks($protocol2, $batch + 1, $batch + 2), 0, "next batch received from the second peer");
is(send_blocks($protocol, $batch + 3, $batch + 3), 0, "the block on top of it received from the first peer");
my @top_requests = grep { $_->[0] eq "sendtx" && $_->[2] == $protocol } @sent;
is(scalar(@top_requests), 1, "transaction of the top block requested from the first peer");
$connection->disconnect(); # the request is lost
undef $connection;
ok(!$protocol->connection, "the first peer is gone");
ok(QBitcoin::Block->is_pending("b" . ($batch + 3)), "its block is still pending");
@sent = grep { $_->[2] == $protocol2 } @sent;
$requested = feed_requested_tx($protocol2);
is($requested->{$top_requests[0]->[1]}, 1, "transaction of the top block requested again via the second peer");
is(scalar(grep { $_ != 1 } values %$requested), 0, "and each transaction once");
is(QBitcoin::Block->blockchain_height, $batch + 3, "the branch is connected via the second peer");

done_testing();
