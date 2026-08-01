#! /usr/bin/env perl
use warnings;
use strict;

# Regression: "Illegal division by zero" in make_out_union when building a sibling
# block. After we publish a stake for the current slot, its input UTXOs are committed
# (is_utxo_published) but its OUTPUT UTXOs are confirmed in the just-published block:
# height H, current slot. make_stake_tx must not treat them as free stake coins for
# the sibling block of the same height H - they do not exist in the sibling's branch
# (built on prev height H-1), and their zero age in the block's own slot made the
# union reward split divide by a zero total weight.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Generate;
use QBitcoin::Generate::Control;

$config->{regtest}   = 1;
$config->{reward_to} = "union";

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

sub confirmed_tx {
    my ($hash_byte, $height, $time) = @_;
    my $tx = QBitcoin::Transaction->new(
        in => [], out => [], tx_type => TX_TYPE_COINBASE, fee => 0,
        hash => pack("H*", $hash_byte x 32),
    );
    $tx->block_height($height);
    $tx->block_time($time);
    $tx->add_to_cache;
    return $tx;
}

sub staked_coin {
    my ($src, $num, $addr, $value) = @_;
    my $txo = QBitcoin::TXO->new_saved({
        tx_in => $src->hash, num => $num, value => $value,
        scripthash => scalar($addr->scripthash), data => "",
    });
    $txo->set_redeem_script($addr->redeem_script) == 0 or die "set_redeem_script\n";
    $txo->add_my_utxo;
    return $txo;
}

my $slot = timeslot(GENESIS_TIME + 1000);

# Old coins, confirmed in the genesis block: the normal stake source.
my $src = confirmed_tx("cc", 0, GENESIS_TIME);
staked_coin($src, 0, $addrA, 2000);
staked_coin($src, 1, $addrB, 1000);

# Publish a stake for the current slot (height 1, prev height 0): both coins are used.
my $stake1 = QBitcoin::Generate::make_stake_tx(10, "block_sign_data", $slot, 0);
is(scalar(@{$stake1->in}), 2, "published stake consumed both old coins");
QBitcoin::Generate::Control->record_stake($slot, $stake1);

# The published block (height 1, current slot) confirms the stake tx; its outputs -
# one per address in union mode - are now our only unpublished staked UTXOs.
my $published = confirmed_tx("dd", 1, $slot);
staked_coin($published, 0, $addrA, 2005);
staked_coin($published, 1, $addrB, 1005);

# Building the sibling stake for the same slot and height (prev height 0) must skip
# the freshly confirmed outputs instead of dying with "Illegal division by zero".
my $stake2 = QBitcoin::Generate::make_stake_tx(10, "block_sign_data2", $slot, 0);
ok(!$stake2 || !@{$stake2->in}, "no free stake coins for the sibling block, no crash");

done_testing();
