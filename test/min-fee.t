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
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(send_block send_tx $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
$config->{regtest} = 1;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });
$transaction_module->mock('size', sub : lvalue { $_[0]->{size} = 1000; $_[0]->{size} });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

blockchain_synced(1);

my $block;
send_block(0, "a0", undef, 50, send_tx());
$block = QBitcoin::Block->best_block(0);
diag("block 0 size: " . $block->size . ", min_fee: " . $block->min_fee) if $config->{debug};

my $tx = send_tx();
send_block(1, "a1", "a0", 52, $tx);
$block = QBitcoin::Block->best_block(1);
diag("block 1 size: " . $block->size . ", min_fee: " . $block->min_fee) if $config->{debug};
is($block->min_fee, 10, "Block 1 min fee is 10");

my $stake = send_tx(-1, $tx);
$last_tx = undef; # We can't spend outputs from the stake tx due to stake maturity
my @tx = map { send_tx(11) } (1..5);
diag("txs: " . join(", ", map { $_->hash_str } @tx)) if $config->{debug};
send_block(2, "a2", "a1", 54, $stake, @tx);
is(QBitcoin::Block->best_block()->height, 1, "Block 2 rejected due to min fee");

$stake = send_tx(-1, $tx);
$last_tx = $tx[2];
send_block(2, "a2", "a1", 54, $stake, $tx[0], $tx[1], $tx[2], send_tx(2));
$block = QBitcoin::Block->best_block(2);
diag("block 2 size: " . $block->size . ", min_fee: " . $block->min_fee) if $config->{debug};
diag("block 2 txs: " . join(", ", map { $_->hash_str } @{$block->transactions})) if $config->{debug};
is(QBitcoin::Block->best_block()->height, 2, "Block 2 accepted");

$stake = send_tx(-1);
$last_tx = undef;
@tx = map { send_tx(12) } (1..10);
# Update received time for sort these txs by input-output chain
foreach my $i (0..$#tx) {
    my $tx = QBitcoin::Transaction->get($tx[$i]->hash);
    $tx->received_time($block->time + $i);
}
my @choosed = QBitcoin::Mempool->choose_for_block($stake->size, $block->time + BLOCK_INTERVAL, $block, 1);
is(scalar(@choosed), 7, "7 txs chosen for block 3");
send_block(3, "a3", "a2", 56, $stake, @tx[0..$#choosed]);
$block = QBitcoin::Block->best_block(3);
is($block->min_fee, 12, "Block 3 min fee is 12");

$stake = send_tx(-1, $tx[$#choosed]);
@tx = map { send_tx(5, undef) } (1..10);
@choosed = QBitcoin::Mempool->choose_for_block($stake->size, $block->time + BLOCK_INTERVAL, $block, 1);
is(scalar(@choosed), scalar(@tx)+1, "all coinbase chosen for block 4");
send_block(4, "a4", "a3", 58, $stake, @tx);
$block = QBitcoin::Block->best_block(4);
is($block->min_fee, 13, "Block 4 min fee is 13");

done_testing();
