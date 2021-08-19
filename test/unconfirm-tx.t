#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;

#$config->{verbose} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('self_weight', \&mock_self_weight);
my $block_hash;
$block_module->mock('calculate_hash', sub { $block_hash });

sub mock_self_weight {
    my $self = shift;
    return $self->{self_weight} //=
        $self->prev_block ? $self->weight - $self->prev_block->weight : $self->weight;
}

my $peer = QBitcoin::Protocol->new(state => STATE_CONNECTED, ip => '127.0.0.1');
# height, hash, prev_hash, $tx_num, weight [, self_weight]
send_blocks([ 0, "a0", undef, 0, 50 ]);
send_blocks(map [ $_, "a$_", "a" . ($_-1), 1, $_*100 ], 1 .. 20);
$peer->cmd_ihave(pack("VQ<a32", 20, 20*120-70, "\xaa" x 32));
send_blocks([ 5, "b5", "a4", 1, 450 ]);
send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*120-70 ], 6 .. 19);

sub send_blocks {
    my @blocks = @_;

    state $value = 10;
    foreach my $block_data (@blocks) {
        my $tx_num = $block_data->[3];
        my @tx;
        foreach (1 .. $tx_num) {
            my $tx = QBitcoin::Transaction->new(
                out            => [ QBitcoin::TXO->new_txo( value => $value, open_script => "txo_$tx_num" ) ],
                in             => [],
                coins_upgraded => $value,
            );
            $value += 10;
            my $tx_data = $tx->serialize;
            $tx->hash = QBitcoin::Transaction::calculate_hash($tx_data);
            $peer->cmd_tx($tx_data);
            push @tx, $tx;
        }

        my $block = QBitcoin::Block->new(
            height       => $block_data->[0],
            hash         => $block_data->[1],
            prev_hash    => $block_data->[2],
            transactions => \@tx,
            weight       => $block_data->[4],
            self_weight  => $block_data->[5],
        );
        $block->merkle_root = $block->calculate_merkle_root();
        my $block_data = $block->serialize;
        $block_hash = $block->hash;
        $peer->cmd_block($block_data);
    }
}

my $height = QBitcoin::Block->blockchain_height;
my $weight = QBitcoin::Block->best_weight;
my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
my $hash   = $block ? $block->hash : undef;
is($height, 19,    "height");
is($hash,   "b19", "hash");
is($weight, 2210,  "weight");

send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*120-70 ], $height+1 .. 30);
my $incore = QBitcoin::Block->min_incore_height;
is($incore, QBitcoin::Block->blockchain_height-INCORE_LEVELS+1, "incore levels");

done_testing();
