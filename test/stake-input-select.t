#! /usr/bin/env perl
use warnings;
use strict;

# Input selection of the stake transaction: UTXO ordered by weight
# (value * age), the max_stake_inputs config limit, and the size guard that
# keeps the heaviest inputs when the signed transaction exceeds the limit.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Config;
use QBitcoin::Const;
use QBitcoin::Address qw( address_by_pubkey wallet_import_format );
use QBitcoin::MyAddress;
use QBitcoin::Crypto qw( generate_keypair );
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Generate;

$config->{regtest} = 1;

my $sh_deleg = "delegated_scripthash_1";

my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my $my_address = QBitcoin::MyAddress->new(
    private_key => wallet_import_format($pk->pk_serialize),
    address     => address_by_pubkey($pk->pubkey_by_privkey, CRYPT_ALGO_ECDSA),
    staked      => 1,
);
my $own_sh = scalar $my_address->scripthash;

my $generate_module = Test::MockModule->new('QBitcoin::Generate');
$generate_module->mock('stake_address', sub { ($my_address) });
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
# The tx_in name encodes the age in slots
$transaction_module->mock('txo_time', sub { $_[1]->tx_in =~ /^u\d+:(\d+)$/ ? $timeslot - $1 * BLOCK_INTERVAL : $timeslot });
$transaction_module->mock('sign_transaction',
    sub {
        foreach my $in (@{$_[0]->in}) {
            # A fixed-size fake signature so that the tx size grows with the inputs
            $in->{siglist} = [ "s" x 64 ];
            $in->{txo}->{redeem_script} = 'redeem_script';
        }
    }
);

# [ value, age, scripthash ] => weight value*age
my @specs = (
    [ 1000, 10, $own_sh   ], # 10000
    [ 5000,  1, $own_sh   ], #  5000
    [  100, 200, $own_sh  ], # 20000
    [ 3000,  2, $own_sh   ], #  6000
    [  700,  3, $sh_deleg ], #  2100
    [  900,  9, $sh_deleg ], #  8100
);
sub create_utxo {
    $_->del_my_utxo() foreach (QBitcoin::TXO->my_utxo, QBitcoin::TXO->staked_utxo);
    my $id = 0;
    foreach my $spec (@specs) {
        my ($value, $age, $scripthash) = @$spec;
        ++$id;
        QBitcoin::TXO->new_txo(
            value      => $value,
            num        => 0,
            tx_in      => "u$id:$age",
            tx_out     => undef,
            scripthash => $scripthash,
        )->add_my_utxo();
    }
}
# The transaction sorts its inputs canonically (tx_in, num), so compare the sets
sub input_values { [ sort { $a <=> $b } map { $_->{txo}->value } @{$_[0]->in} ] }
my @by_weight = map { $_->[0] } sort { $b->[1] <=> $a->[1] } map { [ $_->[0], $_->[0] * $_->[1] ] } @specs;
sub heaviest { [ sort { $a <=> $b } @by_weight[0 .. $_[0] - 1] ] }

$config->{reward_to} = "union";
create_utxo();

# No limit: everything is spent, heaviest first
my $tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is(scalar(@{$tx->in}), 6, "no limit: all utxo spent");
is_deeply([ map { $_->value } QBitcoin::Generate::select_stake_inputs([ QBitcoin::TXO->staked_utxo ], $timeslot) ],
    \@by_weight, "selection ordered by weight");
my $full_size = $tx->size;

# max_stake_inputs: the heaviest ones
$config->{max_stake_inputs} = 3;
$tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is_deeply(input_values($tx), heaviest(3), "max_stake_inputs: the three heaviest utxo");
# Chosen: 100 (20000), 1000 (10000), delegated 900 (8100); the reward 100 is split
# by weight: 30000 : 8100 => 79 : 21
my %out = map { $_->scripthash => $_->value } @{$tx->out};
is($out{$own_sh}, 100 + 1000 + 79, "own output: principal of the chosen inputs plus the reward part");
is($out{$sh_deleg}, 900 + 21, "delegated output: principal plus the reward part");

# Same choice on the probe and the real stake (the two calls per block)
my $probe = QBitcoin::Generate::make_stake_tx("0e0", "", $timeslot);
is_deeply(input_values($probe), input_values($tx), "deterministic selection");

# The next one in (3000, weight 6000) joins the own output
$config->{max_stake_inputs} = 4;
$tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is_deeply(input_values($tx), heaviest(4), "four heaviest utxo");
%out = map { $_->scripthash => $_->value } @{$tx->out};
is($out{$own_sh} + $out{$sh_deleg}, 100 + 1000 + 3000 + 900 + 100, "principals of the four inputs plus the reward");
delete $config->{max_stake_inputs};

# Size guard: with the limit below the full size the heaviest inputs that fit are kept
my $size_limit = int($full_size * 0.6);
$generate_module->mock('max_stake_tx_size', sub { $size_limit });
$tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
ok($tx->size <= $size_limit, "size guard: tx size " . $tx->size . " within the limit $size_limit");
my $n = @{$tx->in};
ok($n >= 1 && $n < 6, "size guard: $n inputs kept");
is_deeply(input_values($tx), heaviest($n), "size guard: the heaviest inputs kept");

# A single input is never dropped even if it does not fit
$size_limit = 10;
$tx = QBitcoin::Generate::make_stake_tx(100, "blocksign", $timeslot);
is(scalar(@{$tx->in}), 1, "size guard: the last input stays");
is($tx->in->[0]{txo}->value, $by_weight[0], "size guard: it is the heaviest one");

done_testing();
