#! /usr/bin/env perl
use warnings;
use strict;

# Output structure of a stake transaction built over delegated UTXOs:
# the reward-address cut, the covenant principals and the weighted
# distribution of the reward remainder in each reward_to mode.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Config;
use QBitcoin::Const;
use QBitcoin::Address qw( address_by_pubkey address_by_hash wallet_import_format );
use QBitcoin::MyAddress;
use QBitcoin::Crypto qw( generate_keypair );
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Generate;

$config->{regtest} = 1;

my $sh_deleg = "delegated_scripthash_1";
my $reward_addr = address_by_hash("\x11" x 20);
my $reward_sh   = QBitcoin::Address::scripthash_by_address($reward_addr);

my $my_address;
my $generate_module = Test::MockModule->new('QBitcoin::Generate');
$generate_module->mock('stake_address', sub { $my_address ? ($my_address) : () });
$generate_module->mock('txo_confirmed', sub { 1 });
my $txo_module = Test::MockModule->new('QBitcoin::TXO');
$txo_module->mock('my_roles', sub {
    $_[0]->scripthash eq $sh_deleg
        ? QBitcoin::Wallet::UTXO::UTXO_DELEGATED
        : QBitcoin::Wallet::UTXO::UTXO_STAKED
});
my $delegation_module = Test::MockModule->new('QBitcoin::Delegation');
$delegation_module->mock('list', sub { () });
$delegation_module->mock('get_by_hash', sub { $_[1] eq $sh_deleg ? {} : undef });
my $timeslot = timeslot(time);
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('txo_stakeable', sub { 1 });
$transaction_module->mock('txo_time', sub { $_[1]->tx_in =~ /age_\d+:(\d+)/ ? $timeslot - $1*10 : 0 });
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

# own: value 2000 age 2 (weight 40000); delegated: value 1000 age 10 (weight 100000)
sub create_utxo {
    my (@specs) = @_;
    @specs = ([ 2000, 2, scalar($my_address->scripthash) ], [ 1000, 10, $sh_deleg ]) unless @specs;
    $_->del_my_utxo() foreach (QBitcoin::TXO->my_utxo, QBitcoin::TXO->staked_utxo);
    my $id = 0;
    foreach my $spec (@specs) {
        my ($amount, $age, $scripthash) = @$spec;
        ++$id;
        my $utxo = QBitcoin::TXO->new_txo(
            value      => $amount,
            num        => 0,
            tx_in      => "age_$id:$age",
            tx_out     => undef,
            scripthash => $scripthash,
        );
        $utxo->add_my_utxo();
    }
}

sub outputs {
    my ($tx) = @_;
    return map { [ $_->scripthash, $_->value ] } @{$tx->out};
}

generate_my_address();
create_utxo();
my $own_sh = scalar $my_address->scripthash;

# The delegate keeps 20% of the reward, the remainder is split by weight
$config->{reward_addr} = "$reward_addr 0.2";

$config->{reward_to} = "union";
my $tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is_deeply([ outputs($tx) ],
    [ [ $reward_sh, 20 ], [ $own_sh, 2023 ], [ $sh_deleg, 1057 ] ],
    "union: cut, own + part, delegated principal + part");
is(sum0(map { $_->value } @{$tx->out}), 3100, "union: reward fully distributed");

$config->{reward_to} = "join";
$tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is_deeply([ outputs($tx) ],
    [ [ $reward_sh, 20 ], [ $own_sh, 2080 ], [ $sh_deleg, 1000 ] ],
    "join: cut, own gets the remainder, delegated principal intact");

$config->{reward_to} = "separate";
$tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is_deeply([ outputs($tx) ],
    [ [ $reward_sh, 20 ], [ $sh_deleg, 1080 ] ],
    "separate: best (delegated) address gets principal + remainder");
is(scalar(@{$tx->in}), 1, "separate: only the delegated utxo spent");

# No share configured: the whole reward goes to the reward address,
# the delegated principal is preserved
$config->{reward_addr} = $reward_addr;
$config->{reward_to} = "union";
create_utxo();
$tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is_deeply([ outputs($tx) ],
    [ [ $reward_sh, 100 ], [ $own_sh, 2000 ], [ $sh_deleg, 1000 ] ],
    "union without share: full cut, principals intact");

# No reward_addr at all: everything is distributed to the staking addresses
delete $config->{reward_addr};
create_utxo();
$tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is_deeply([ outputs($tx) ],
    [ [ $own_sh, 2029 ], [ $sh_deleg, 1071 ] ],
    "union without reward_addr: split by weight only");

# Delegate node with no own stake address, join mode: the remainder must not
# be lost - it falls back to the weighted distribution over delegated UTXOs
$config->{reward_addr} = "$reward_addr 0.2";
$config->{reward_to} = "join";
create_utxo([ 1000, 10, $sh_deleg ]);
$my_address = undef;
$tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is_deeply([ outputs($tx) ],
    [ [ $reward_sh, 20 ], [ $sh_deleg, 1080 ] ],
    "join without own address: remainder to the delegated address");

done_testing;
