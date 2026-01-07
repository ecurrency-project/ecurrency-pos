#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Config;
use QBitcoin::Const;
use QBitcoin::Address qw( address_by_pubkey wallet_import_format );
use QBitcoin::MyAddress;
use QBitcoin::Crypto qw( generate_keypair );
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Generate;

#$config->{debug} = 1;
$config->{regtest} = 1;

my $my_address;
my $generate_module = Test::MockModule->new('QBitcoin::Generate');
$generate_module->mock('stake_address', sub { $my_address });
$generate_module->mock('txo_confirmed', sub { 1 });
my $txo_module = Test::MockModule->new('QBitcoin::TXO');
$txo_module->mock('is_staked', sub { 1 });
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('txo_time', sub { $_[1]->tx_in =~ /age_\d+:(\d+)/ ? timeslot(time) - $1*10 : 0 });
$transaction_module->mock('sign_transaction',
    sub {
        foreach my $in (@{$_[0]->in}) {
            $in->{siglist} = [];
            $in->{txo}->{redeem_script} = 'redeem_script';
        }
    }
);

sub generate_my_address {
    my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
    $my_address = QBitcoin::MyAddress->new(
        private_key => wallet_import_format($pk->pk_serialize),
        address     => address_by_pubkey($pk->pubkey_by_privkey, CRYPT_ALGO_ECDSA),
        staked      => 1,
    );
}

sub create_my_utxo {
    $_->del_my_utxo() foreach QBitcoin::TXO->my_utxo;
    my $id = 0;
    foreach my $amount_age ([ 2000 => 2 ], [ 1000 => 10 ], [ 10 => 2 ]) {
        my ($amount, $age) = @$amount_age;
        ++$id;
        my $utxo = QBitcoin::TXO->new_txo(
            value      => $amount,
            num        => 0,
            tx_in      => "age_$id:$age",
            tx_out     => undef,
            scripthash => "scripthash_" . $id,
        );
        $utxo->add_my_utxo();
    }
}

generate_my_address();
create_my_utxo();

$config->{reward_to} = "join";
my $tx = QBitcoin::Generate::make_stake_tx("10", "blocksign");
is(scalar(@{$tx->out}), 1, "Stake tx has one output in join mode");
is($tx->out->[0]->value, 3020, "Stake tx output value is correct");
is(scalar(@{$tx->in}), 3, "Stake tx has three inputs in join mode");

$config->{reward_to} = "union";
$tx = QBitcoin::Generate::make_stake_tx("10", "blocksign");
is(scalar(@{$tx->out}), 2, "Stake tx has two outputs in union mode");
is($tx->out->[0]->value, 2003, "First output value is correct");
is($tx->out->[0]->scripthash, "scripthash_1", "First output scripthash is correct");
is($tx->out->[1]->value, 1007, "Second output value is correct");
is($tx->out->[1]->scripthash, "scripthash_2", "Second output scripthash is correct");
is(scalar(@{$tx->in}), 2, "Stake tx has two inputs in union mode");

$config->{reward_to} = "separate";
$tx = QBitcoin::Generate::make_stake_tx("10", "blocksign");
is(scalar(@{$tx->out}), 1, "Stake tx has one output in separate mode");
is($tx->out->[0]->value, 1010, "Output value is correct");
is($tx->out->[0]->scripthash, "scripthash_2", "Output scripthash is correct");
is(scalar(@{$tx->in}), 1, "Stake tx has one input in separate mode");

done_testing;
