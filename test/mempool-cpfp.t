#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(send_block send_tx send_raw_tx $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Mempool;

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

# make_tx() builds only single-output transactions spending out->[0];
# these two build a transaction with two outputs and one spending arbitrary txos
sub make_tx2 {
    my ($prev_txs, $fee) = @_;
    my @in = map { $_->out->[0] } @$prev_txs;
    my $script = op_pushdata(pack("v", 1)) . OP_DROP . OP_1;
    my $scripthash = hash160($script);
    $SCRIPT{$scripthash} = $script;
    $_->{redeem_script} = ($SCRIPT{$_->scripthash} // die "Unknown redeem script\n") foreach @in;
    my $out_value = sum0(map { $_->value } @in) - $fee;
    my $half = int($out_value / 2);
    my $tx = QBitcoin::Transaction->new(
        out => [
            QBitcoin::TXO->new_txo( value => $half,              scripthash => $scripthash, num => 0, data => "" ),
            QBitcoin::TXO->new_txo( value => $out_value - $half, scripthash => $scripthash, num => 1, data => "" ),
        ],
        in      => [ map +{ txo => $_, siglist => [] }, @in ],
        fee     => $fee,
        tx_type => TX_TYPE_STANDARD,
    );
    $tx->calculate_hash;
    my $num = 0;
    foreach my $out (@{$tx->out}) {
        $out->tx_in = $tx->hash;
        $out->num = $num++;
    }
    return send_raw_tx($tx);
}

sub make_tx_in {
    my ($txos, $fee) = @_;
    my $script = op_pushdata(pack("v", 2)) . OP_DROP . OP_1;
    my $scripthash = hash160($script);
    $SCRIPT{$scripthash} = $script;
    $_->{redeem_script} = ($SCRIPT{$_->scripthash} // die "Unknown redeem script\n") foreach @$txos;
    my $out = QBitcoin::TXO->new_txo( value => sum0(map { $_->value } @$txos) - $fee, scripthash => $scripthash, num => 0, data => "" );
    my $tx = QBitcoin::Transaction->new(
        out     => [ $out ],
        in      => [ map +{ txo => $_, siglist => [] }, @$txos ],
        fee     => $fee,
        tx_type => TX_TYPE_STANDARD,
    );
    $tx->calculate_hash;
    $out->tx_in = $tx->hash;
    return send_raw_tx($tx);
}

sub tx_names {
    my ($names, @tx) = @_;
    return join(",", map { $names->{$_->hash} // $_->hash_str } @tx);
}

send_block(0, "a0", undef, 50, send_tx());

# Confirmed outputs to spend in the test scenarios
my @base = map { $last_tx = undef; send_tx(0) } (1..14);
send_block(1, "a1", "a0", 52, @base);
my $block = QBitcoin::Block->best_block(1);
is($block && $block->height, 1, "setup blocks accepted");

# --- a service-style chain: every next tx spends an output of the previous one
# and pays a higher fee (as fee estimation grows with the mempool).
# The old per-tx feerate sort skipped children of unconfirmed parents,
# so only the head of the chain was included in each block.
$last_tx = $base[0];
my @chain = map { send_tx(20 + 2*$_) } (0..4);
my $stake = send_tx(-1, $base[10]);
my @chosen = QBitcoin::Mempool->choose_for_block($stake->size, $block->time + BLOCK_INTERVAL, $block, 1);
is(scalar(@chosen), 5, "whole fee-ascending chain chosen for one block");
is_deeply([map { $_->hash } @chosen], [map { $_->hash } @chain], "chain included in topological order");
send_block(2, "a2", "a1", 54, $stake, @chosen);
$block = QBitcoin::Block->best_block();
is($block && $block->height, 2, "block with the chain accepted");

# --- CPFP: the child pays for its low-fee parent, the package outranks
# an independent transaction with a better feerate than the parent alone
my $parent = send_tx(2, $base[1]);
my $child  = send_tx(60, $parent);
my $other  = send_tx(25, $base[2]);
$stake = send_tx(-1, $base[11]);
@chosen = QBitcoin::Mempool->choose_for_block($stake->size, $block->time + BLOCK_INTERVAL, $block, 1);
my %names = map { $_->[0]->hash => $_->[1] }
    [$parent, "parent"], [$child, "child"], [$other, "other"];
is(tx_names(\%names, @chosen), "parent,child,other", "CPFP package first, then the independent tx");
send_block(3, "a3", "a2", 56, $stake, @chosen);
$block = QBitcoin::Block->best_block();
is($block && $block->height, 3, "block with the CPFP package accepted");

# --- a cheap child must not ride on the score of its expensive parent;
# it competes on its own feerate and takes the single below-min_fee slot,
# so another low-fee transaction is left in the mempool
my $parent2 = send_tx(50, $base[3]);
my $child2  = send_tx(1, $parent2);
my $other2  = send_tx(30, $base[4]);
$last_tx = undef;
my $poor    = send_tx(1, $base[5]);
QBitcoin::Transaction->get($child2->hash)->received_time($block->time + 1);
QBitcoin::Transaction->get($poor->hash)->received_time($block->time + 2);
$stake = send_tx(-1, $base[6]);
@chosen = QBitcoin::Mempool->choose_for_block($stake->size, $block->time + BLOCK_INTERVAL, $block, 1);
%names = map { $_->[0]->hash => $_->[1] }
    [$parent2, "parent2"], [$child2, "child2"], [$other2, "other2"], [$poor, "poor"];
is(tx_names(\%names, @chosen), "parent2,other2,child2",
    "cheap child chosen last on its own feerate, second low-fee tx does not fit the quota");
send_block(4, "a4", "a3", 58, $stake, @chosen);
$block = QBitcoin::Block->best_block();
is($block && $block->height, 4, "block with the low-fee quota filled accepted");
QBitcoin::Transaction->get($poor->hash)->drop();

# --- diamond dependency: D spends outputs of B and C, both spend outputs of A;
# the package fee of D must count A only once
my $tx_a = make_tx2([$base[7]], 10);
my $tx_b = make_tx_in([$tx_a->out->[0]], 10);
my $tx_c = make_tx_in([$tx_a->out->[1]], 10);
my $tx_d = make_tx_in([$tx_b->out->[0], $tx_c->out->[0]], 80);
$stake = send_tx(-1, $base[8]);
@chosen = QBitcoin::Mempool->choose_for_block($stake->size, $block->time + BLOCK_INTERVAL, $block, 1);
%names = map { $_->[0]->hash => $_->[1] }
    [$tx_a, "A"], [$tx_b, "B"], [$tx_c, "C"], [$tx_d, "D"];
is(tx_names(\%names, @chosen), "A,B,C,D", "diamond-dependent package included in topological order");
send_block(5, "a5", "a4", 60, $stake, @chosen);
$block = QBitcoin::Block->best_block();
is($block && $block->height, 5, "block with the diamond package accepted");

# --- conflicting packages: two transactions spend the same output; the winner
# is the package with the better score, the loser is left out
my $spend_a = send_tx(40, $base[9]);
my $spend_b = send_tx(2, $base[9]);
SKIP: {
    skip "mempool does not accept conflicting transactions", 2 unless $spend_b;
    my $child_b = send_tx(90, $spend_b);
    $stake = send_tx(-1, $base[12]);
    @chosen = QBitcoin::Mempool->choose_for_block($stake->size, $block->time + BLOCK_INTERVAL, $block, 1);
    %names = map { $_->[0]->hash => $_->[1] }
        [$spend_a, "spend_a"], [$spend_b, "spend_b"], [$child_b, "child_b"];
    is(tx_names(\%names, @chosen), "spend_b,child_b", "CPFP package outbids the conflicting single tx");
    send_block(6, "a6", "a5", 62, $stake, @chosen);
    $block = QBitcoin::Block->best_block();
    is($block && $block->height, 6, "block with the conflict winner accepted");
}

done_testing();
