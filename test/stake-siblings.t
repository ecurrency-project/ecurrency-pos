#! /usr/bin/env perl
use warnings;
use strict;

# reward_to = separate: a stake uses only one of our addresses. After we publish a
# stake for a slot, make_stake_tx must skip its (now committed) UTXOs and pick a still
# -free address, so a sibling block can be built for the same slot with a different
# address - as if it were another node.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Generate;
use QBitcoin::Generate::Control;

$config->{regtest}  = 1;
$config->{reward_to} = "separate";

# is_utxo_published primitive
{
    package FakeTXO; sub key { $_[0]->{k} } sub new { bless { k => $_[1] }, $_[0] }
    package FakeTx;  sub hash { $_[0]->{h} } sub in { $_[0]->{in} } sub new { bless { h => $_[1], in => $_[2] }, $_[0] }
}
my $C = 'QBitcoin::Generate::Control';
my $ftx = FakeTx->new("H", [ { txo => FakeTXO->new("u1") } ]);
ok(!$C->is_utxo_published(1000, "u1"), "utxo not published initially");
$C->record_stake(1000, $ftx);
ok($C->is_utxo_published(1000, "u1"),  "utxo published after record_stake");
ok(!$C->is_utxo_published(1000, "u2"), "a different utxo is not published");
ok(!$C->is_utxo_published(1001, "u1"), "same utxo in another slot is not published");

# Two staked addresses with one confirmed staked coin each (A heavier than B).
sub make_address {
    my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
    my ($addr) = addresses_by_pubkey($pk->pubkey_by_privkey, CRYPT_ALGO_ECDSA);
    return QBitcoin::MyAddress->create({
        private_key => wallet_import_format($pk->pk_serialize),
        address     => $addr,
        staked      => 1,
    });
}
my $addrA = make_address();
my $addrB = make_address();

# a confirmed transaction whose outputs are our staked coins (so txo_confirmed passes)
my $src = QBitcoin::Transaction->new(in => [], out => [], tx_type => TX_TYPE_COINBASE, fee => 0, hash => pack("H*", "cc" x 32));
$src->block_height(0);
$src->block_time(GENESIS_TIME);
$src->add_to_cache;

sub staked_coin {
    my ($num, $addr, $value) = @_;
    my $txo = QBitcoin::TXO->new_saved({
        tx_in => $src->hash, num => $num, value => $value,
        scripthash => scalar($addr->scripthash), data => "",
    });
    $txo->set_redeem_script($addr->redeem_script) == 0 or die "set_redeem_script\n";
    $txo->add_my_utxo;
    return $txo;
}
my $coinA = staked_coin(0, $addrA, 2000); # heavier
my $coinB = staked_coin(1, $addrB, 1000);

my $slot = timeslot(GENESIS_TIME + 1000);

# First stake picks the heavier address A.
my $stake1 = QBitcoin::Generate::make_stake_tx("0e0", "", $slot);
ok($stake1, "first stake built");
is($stake1->in->[0]{txo}->scripthash, scalar($addrA->scripthash), "first stake uses the heavier address A");

# Publish A's stake for this slot.
QBitcoin::Generate::Control->record_stake($slot, $stake1);

# Next stake in the same slot must skip A and use the still-free address B.
my $stake2 = QBitcoin::Generate::make_stake_tx("0e0", "", $slot);
ok($stake2, "sibling stake built with a free address");
is($stake2->in->[0]{txo}->scripthash, scalar($addrB->scripthash), "sibling stake uses the free address B");

# Once both are published, no free address remains -> no stake.
QBitcoin::Generate::Control->record_stake($slot, $stake2);
my $stake3 = QBitcoin::Generate::make_stake_tx("0e0", "", $slot);
ok(!$stake3 || !@{$stake3->in}, "no stake when all addresses are already used this slot");

done_testing();
