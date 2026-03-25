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

# Deep reorg test: synced node receives alternative chain with higher weight
# Blocks arrive in reverse order (tip first, walking back to common ancestor)
# This simulates the sendblock chain during deep fork synchronization
#
# Bug: when a block with unknown ancestor has pending_descendants and blockchain_synced(),
# the block was discarded instead of saved as pending, breaking the chain

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
$config->{regtest} = 1;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => '127.0.0.1');
my $connection = QBitcoin::Connection->new(peer => $peer, state => STATE_CONNECTED);

sub send_block {
    my ($height, $hash, $prev_hash, $tx_num, $weight, $self_weight) = @_;

    state $value = 10;
    my @tx;
    foreach (1 .. ($tx_num // 0)) {
        my $tx = QBitcoin::Transaction->new(
            out           => [ QBitcoin::TXO->new_txo( value => $value, scripthash => hash160("txo_$height"), data => "" ) ],
            in            => [],
            coins_created => $value,
            tx_type       => TX_TYPE_COINBASE,
        );
        $value += 10;
        $tx->calculate_hash;
        push @tx, $tx;
    }

    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + $height * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => \@tx,
        weight       => $weight,
        self_weight  => $self_weight,
    );
    $block->merkle_root = $block->calculate_merkle_root();
    my $block_data = $block->serialize;
    block_hash($block->hash);
    $connection->protocol->cmd_block($block_data);

    # Send transactions so blocks are not pending for tx
    foreach my $tx (@tx) {
        $connection->protocol->cmd_tx($tx->serialize . "\x00"x16);
    }
}

# Build main chain: a0 (genesis) -> a1 -> ... -> a10
# height, hash, prev_hash, tx_num, weight
send_block(0, "a0", undef, 0, 50);
send_block($_, "a$_", "a" . ($_ - 1), 1, $_ * 100) foreach 1 .. 10;
blockchain_synced(1);

my $height = QBitcoin::Block->blockchain_height;
my $best   = QBitcoin::Block->best_block;
is($height,      10, "main chain height 10");
is($best->hash, "a10", "main chain best block a10");

# Alternative chain: fork at a5, blocks c6..c10 with much higher weight
# Fork depth = 10 - 5 = 5, less than INCORE_LEVELS(6), so no reorg penalty
# Send in REVERSE order (tip first) to simulate sendblock chain walk-back
#
# Expected flow with fix:
#   c10: unknown ancestor c9, no pending_descendants -> save as pending
#   c9:  unknown ancestor c8, pending_descendants={c10} -> save as pending (FIX)
#   c8:  unknown ancestor c7, pending_descendants={c9}  -> save as pending (FIX)
#   c7:  unknown ancestor c6, pending_descendants={c8}  -> save as pending (FIX)
#   c6:  ancestor a5 known -> receive -> process_pending cascades c7->c8->c9->c10
#
# Expected flow with bug:
#   c10: save as pending
#   c9:  pending_descendants={c10} -> DISCARDED (batch path)
#   c8:  no pending_descendants -> save as pending
#   c7:  pending_descendants={c8} -> DISCARDED (batch path)
#   c6:  ancestor a5 known -> receive -> cascade stops (c7 was discarded)
#   Result: only c6 processed, c8/c10 orphaned as pending

foreach my $h (reverse 6 .. 10) {
    my $prev = $h == 6 ? "a5" : "c" . ($h - 1);
    send_block($h, "c$h", $prev, 0, $h * 5000);
}

$height = QBitcoin::Block->blockchain_height;
$best   = QBitcoin::Block->best_block;
is($height,      10, "deep reorg: height stays 10");
is($best->hash, "c10", "deep reorg: alternative chain c10 becomes best");
is($best->weight, 50000, "deep reorg: correct weight");

done_testing();
