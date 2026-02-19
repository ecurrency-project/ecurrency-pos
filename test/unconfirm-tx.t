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
use QBitcoin::Crypto qw(hash160);
use Bitcoin::Serialized;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
$config->{regtest} = 1;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => '127.0.0.1');
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
blockchain_synced(1);

sub send_blocks {
    my @blocks = @_;

    state $value = 10;
    foreach my $block_data (@blocks) {
        my $tx_num = $block_data->[3];
        my @tx;
        $connection->protocol->command("tx");
        foreach (1 .. $tx_num) {
            my $tx = QBitcoin::Transaction->new(
                out           => [ QBitcoin::TXO->new_txo( value => $value, scripthash => hash160("txo_$tx_num"), data => "" ) ],
                in            => [],
                coins_created => $value,
                tx_type       => TX_TYPE_COINBASE,
            );
            $value += 10;
            $tx->calculate_hash;
            $connection->protocol->cmd_tx($tx->serialize . "\x00"x16);
            push @tx, $tx;
        }

        my $block = QBitcoin::Block->new(
            time         => GENESIS_TIME + $block_data->[0] * BLOCK_INTERVAL * FORCE_BLOCKS,
            hash         => $block_data->[1],
            prev_hash    => $block_data->[2],
            transactions => \@tx,
            weight       => $block_data->[4],
            self_weight  => $block_data->[5],
        );
        $block->merkle_root = $block->calculate_merkle_root();
        my $block_data = $block->serialize;
        block_hash($block->hash);
        $connection->protocol->command("block");
        $connection->protocol->cmd_block($block_data);
    }
}

# height, hash, prev_hash, $tx_num, weight [, self_weight]
send_blocks([ 0, "a0", undef, 0, 50 ]);
send_blocks(map [ $_, "a$_", "a" . ($_-1), 1, $_*100 ], 1 .. 20);
$connection->protocol->cmd_ihave(pack("VQ<a32", GENESIS_TIME + 20 * BLOCK_INTERVAL * FORCE_BLOCKS, 20*120-70, "\xaa" x 32));
send_blocks([ 5, "b5", "a4", 1, 450 ]);
send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*2500-70 ], 6 .. 19);

my $height = QBitcoin::Block->blockchain_height;
my $weight = QBitcoin::Block->best_weight;
my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
my $hash   = $block ? $block->hash : undef;
is($height,    19, "height");
is($hash,   "b19", "hash");
is($weight, 47430, "weight");

send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*2500-70 ], 21 .. 30);
send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*2500-70 ], 20);
send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*2500-70 ], 31 .. 35);
QBitcoin::Block->store_blocks();
QBitcoin::Block->cleanup_old_blocks();
my $incore = QBitcoin::Block->min_incore_height;
is($incore, (QBitcoin::Block->blockchain_height // -1) - INCORE_LEVELS + 1, "incore levels");

done_testing();
