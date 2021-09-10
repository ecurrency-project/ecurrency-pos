#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use List::Util qw(sum sum0);
use Test::More;
use Test::MockModule;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Protocol;
use QBitcoin::Mempool;
use QBitcoin::Crypto qw(hash160);

#$config->{debug} = 1;

my $txo_module = Test::MockModule->new('QBitcoin::TXO');
$txo_module->mock('check_script', sub { 0 });
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $peer = QBitcoin::Protocol->new(state => STATE_CONNECTED, ip => '127.0.0.1');

sub make_tx {
    my @in = @_;
    state $value = 10;
    state $tx_num = 1;
    my $out_value = @in ? sum(map { $_->value } @in) : $value;
    $_->redeem_script = "open_ " . $_->value foreach @in;
    my $tx = QBitcoin::Transaction->new(
        out => [ QBitcoin::TXO->new_txo( value => $out_value, scripthash => hash160("open_$out_value") ) ],
        in  => [ map +{ txo => $_, siglist => [] }, @in ],
        @in ? () : ( coins_created => $out_value ),
    );
    $value += 10;
    $tx_num++;
    $tx->calculate_hash;
    my $num = 0;
    foreach my $out (@{$tx->out}) {
        $out->tx_in = $tx->hash;
        $out->num = $num++;
    }
    $peer->command = "tx";
    $peer->cmd_tx($tx->serialize);
    return QBitcoin::Transaction->get($tx->hash);
}

my $tx1 = make_tx();
my $tx2 = make_tx();
my $tx3 = make_tx($tx1->out->[0]);
my $tx4 = make_tx($tx2->out->[0], $tx3->out->[0]);

# Set $tx1 as spent confirmed
$tx1->block_height = 12;
$tx1->out->[0]->tx_out = "abcd";
# Set $tx2 as confirmed
$tx2->block_height = 12;

my @mempool = QBitcoin::Mempool->choose_for_block(0, 20);

is(scalar(@mempool), 0, "transactions dropped");

done_testing();
