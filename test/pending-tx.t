#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(send_block $connection);
use QBitcoin::Config;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;

#$config->{debug} = 1;
$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

sub pending_one {
    my $coinbase_tx = make_tx(undef, 0);
    my $test_tx = make_tx($coinbase_tx, 0);
    my $tx = make_tx;
    # height, hash, prev_hash, weight, $tx
    send_block(0, "a0", undef, 50, $tx);
    my $zero_ip = "\x00"x16;
    $connection->protocol->command = "tx";
    $connection->protocol->cmd_tx($tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($coinbase_tx->serialize . $zero_ip);
    QBitcoin::Transaction->cleanup_mempool();
    send_block(1, "a1", "a0", 100, $coinbase_tx, $test_tx);
    $connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($coinbase_tx->serialize . $zero_ip);

    my $height = QBitcoin::Block->blockchain_height;
    my $weight = QBitcoin::Block->best_weight;
    my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
    my $hash   = $block ? $block->hash : undef;
    is($height,   1, "height");
    is($hash,  "a1", "hash"  );
    is($weight, 100, "weight");
    is(scalar(@{$block->transactions}), 2, "transactions");
}

sub pending_two {
    my $coinbase_tx = make_tx(undef, 0);
    my $tx = make_tx();
    my $test_tx = make_tx([ $coinbase_tx, $tx ], 0);
    # height, hash, prev_hash, weight, $tx
    my $zero_ip = "\x00"x16;
    $connection->protocol->command = "tx";
    $connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($coinbase_tx->serialize . $zero_ip);
    QBitcoin::Transaction->cleanup_mempool();
    send_block(1, "b1", "a0", 300, $coinbase_tx, $tx, $test_tx);
    $connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($coinbase_tx->serialize . $zero_ip);

    my $height = QBitcoin::Block->blockchain_height;
    my $weight = QBitcoin::Block->best_weight;
    my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
    my $hash   = $block ? $block->hash : undef;
    is($height,   1, "height");
    is($hash,  "b1", "hash"  );
    is($weight, 300, "weight");
    is(scalar(@{$block->transactions}), 3, "transactions");
}

pending_one();
pending_two();
done_testing();
