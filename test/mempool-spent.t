#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use List::Util qw(sum0);
use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::Send qw(send_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Mempool;

#$config->{debug} = 1;

my $txo_module = Test::MockModule->new('QBitcoin::TXO');
$txo_module->mock('check_script', sub { 0 });
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

sub send_tx_get {
    my @prev_tx = @_;
    my $tx = send_tx(0, \@prev_tx);
    return QBitcoin::Transaction->get($tx->hash);
}

my $tx1 = send_tx_get();
my $tx2 = send_tx_get();
my $tx3 = send_tx_get($tx1);
my $tx4 = send_tx_get($tx2, $tx3);


# Set $tx1 as spent confirmed
$tx1->block_height = 12;
$tx1->out->[0]->tx_out = "abcd";
# Set $tx2 as confirmed
$tx2->block_height = 12;

QBitcoin::Transaction->cleanup_mempool();

my @mempool = QBitcoin::Mempool->choose_for_block(0, 20, 0, 0);

is(scalar(@mempool), 0, "transactions dropped");

done_testing();
