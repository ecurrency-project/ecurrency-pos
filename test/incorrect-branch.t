#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Generate;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use Bitcoin::Serialized;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => IPV6_V4_PREFIX . pack("C4", split(/\./, "127.0.0.1")));
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
blockchain_synced(1);

sub make_tx {
    my ($prev_tx, $fee) = @_;
    state $value = 10;
    state $tx_num = 1;
    my $val = $prev_tx ? $prev_tx->out->[0]->value : $value;
    $fee //= 0;
    my @out;
    my @in;
    push @in, { txo => $prev_tx->out->[0], siglist => [] } if $prev_tx;
    my $script = OP_1;
    my $out = QBitcoin::TXO->new_txo( value => $val - $fee, scripthash => hash160($script), redeem_script => $script, num => 0 );
    my $tx = QBitcoin::Transaction->new(
        out => [ $out ],
        in  => \@in,
        $prev_tx ? () : ( coins_created => $val ),
    );
    $value += 10;
    $tx_num++;
    $out->tx_in = $tx->calculate_hash;
    return $tx;
}

sub send_block {
    my ($height, $hash, $prev_hash, $weight, @tx) = @_;
    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + $height * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => \@tx,
        weight       => $weight,
    );
    $block->add_tx($_) foreach @tx;
    $block->merkle_root = $block->calculate_merkle_root();
    my $block_data = $block->serialize;
    block_hash($block->hash);
    $connection->protocol->cmd_block($block_data);
}

my $stake_tx = make_tx(undef, -2);
my $test_tx = make_tx($stake_tx, 2);
my $tx1 = make_tx;
my $tx2 = make_tx($tx1, 0);
# height, hash, prev_hash, weight, $tx
send_block(0, "a0", undef, 100);
my $zero_ip = "\x00"x16;
$connection->protocol->command = "tx";
$connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
$connection->protocol->cmd_tx($tx1->serialize . $zero_ip);
$connection->protocol->cmd_tx($tx2->serialize . $zero_ip);
QBitcoin::Transaction->cleanup_mempool();
send_block(1, "a1", "a0", 200, $stake_tx, $test_tx);
$connection->protocol->cmd_tx($stake_tx->serialize . $zero_ip);
send_block(2, "a2", "a1", 300, $tx1);
send_block(3, "a3", "a2", 400, $tx2);
$connection->protocol->cmd_ihave(pack("VQ<a32", GENESIS_TIME + 3 * BLOCK_INTERVAL * FORCE_BLOCKS, 410, "\xaa" x 32));

# Incorrect transactions order
send_block(1, "b1", "a0", 190, $tx2);
send_block(2, "b2", "b1", 290);
send_block(3, "b3", "b2", 410, $tx1);
is(QBitcoin::Block->best_weight, 400, "incorrect transaction order");

# Transaction included twice in block
send_block(1, "c1", "a0", 190, $tx1, $tx1);
send_block(2, "c2", "c1", 290);
send_block(3, "c3", "c2", 410);
is(QBitcoin::Block->best_weight, 400, "transaction included twice in block");

# Process stake tx twice
my $stake_tx2 = make_tx(undef, -2);
my $test_tx2 = make_tx($stake_tx, 2);
my $tx3 = make_tx(undef, 0);
send_block(1, "d1", "a0", 190, $tx3);
send_block(2, "d2", "d1", 290);
send_block(3, "d3", "d2", 410, $stake_tx2, $test_tx2, $tx3);
$connection->protocol->cmd_tx($test_tx2->serialize . $zero_ip);
$connection->protocol->cmd_tx($stake_tx2->serialize . $zero_ip);
$connection->protocol->cmd_tx($tx3->serialize . $zero_ip);
QBitcoin::Transaction->cleanup_mempool();
is(QBitcoin::Block->best_weight, 400, "revert stake tx");
send_block(1, "d1", "a0", 190, $tx3);
send_block(2, "d2", "d1", 290);
send_block(3, "d3", "d2", 410, $stake_tx2, $test_tx2, $tx3);
$connection->protocol->cmd_tx($stake_tx2->serialize . $zero_ip);
is(QBitcoin::Block->best_weight, 400, "revert stake tx once more");

# Correct alternative branch
send_block(1, "z1", "a0", 190, $tx1);
send_block(2, "z2", "z1", 290);
send_block(3, "z3", "z2", 410, $tx2);
is(QBitcoin::Block->best_weight, 410, "correct alternative branch");

done_testing();
