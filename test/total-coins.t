#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(hash160 generate_keypair);
use QBitcoin::Coinbase;
use QBitcoin::Coins;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Block;
use QBitcoin::Generate;
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;

$config->{regtest} = 1;
$config->{genesis} = 1;
$config->{genesis_reward} = GENESIS_REWARD;

my $coinbase_module = Test::MockModule->new('QBitcoin::Coinbase');
$coinbase_module->mock('validate', sub { 0 });

my $time = time() - BLOCK_INTERVAL * FORCE_BLOCKS;
$time -= $time % (BLOCK_INTERVAL * FORCE_BLOCKS);
my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my $pubkey = $pk->pubkey_by_privkey;
my ($address) = addresses_by_pubkey($pubkey, CRYPT_ALGO_ECDSA);
QBitcoin::MyAddress->create({
    private_key => wallet_import_format($pk->pk_serialize),
    address     => $address,
    staked      => 1,
});

my $value = 100000; # random btc value to upgrade
my $open_script = "\x10\x11";
my $up = QBitcoin::Coinbase->new({
    btc_block_height => 10,
    btc_tx_num       => 0,
    btc_out_num      => 0,
    btc_block_hash   => "aa" x 32,
    btc_tx_hash      => "bb" x 32,
    btc_tx_data      => "cc" x 80,
    merkle_path      => "dd" x 32,
    value_btc        => $value,
    value            => $value,
    upgrade_level    => 0,
    scripthash       => hash160($open_script),
});
$up->{btc_confirm_time} = $time - COINBASE_CONFIRM_TIME - 15;

my $out = QBitcoin::TXO->new_txo({
    value      => int($value * (1 - UPGRADE_FEE)),
    scripthash => hash160($open_script),
    data       => "",
});

sub coinbase_tx {
    my $tx = QBitcoin::Transaction->new({
        in            => [],
        out           => [ $out ],
        up            => $up,
        tx_type       => TX_TYPE_COINBASE,
        upgrade_level => 0,
    });
    $tx->calculate_fee;
    $tx->calculate_hash;
    return $tx;
}

# Initialize the counter on an empty database: no chain yet => 0
QBitcoin::Coins->init();
is(QBitcoin::Coins->total(), 0, "No coins before genesis");

# Genesis block: emission is exactly the genesis reward
my $block0 = QBitcoin::Generate->generate($time);
ok($block0, "Generated genesis block");
is(QBitcoin::Coins->total(), GENESIS_REWARD, "Genesis reward counted");

# Block with a coinbase (upgrade): full upgraded value (pre-fee) is added
my $tx = coinbase_tx();
$out->tx_out = $tx->hash;
$out->num = 0;
is($tx->validate(), 0, "Correct coinbase");
$tx->add_to_cache();

my $block1 = QBitcoin::Generate->generate($time + BLOCK_INTERVAL);
ok($block1, "Generated block 1 with coinbase");
my $static_reward = $block1->static_reward($block0, $block1->time);
is(QBitcoin::Coins->total(), GENESIS_REWARD + $value + $static_reward, "Upgrade emission counted (full value incl fee)");

# Unconfirm the best block: emission must roll back to the previous value
$block1->unconfirm();
is(QBitcoin::Block->blockchain_height, 0, "Back to genesis height");
is(QBitcoin::Coins->total(), GENESIS_REWARD, "Coinbase emission removed on unconfirm");

done_testing();
