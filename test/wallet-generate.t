#! /usr/bin/env perl
use warnings;
use strict;

# Block generation with encrypted wallet keys: a locked wallet cannot sign a
# stake transaction, unlocking resumes generation (see also generate.t).

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Test::Send qw(send_tx send_block $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Transaction;
use QBitcoin::Block;
use QBitcoin::Generate;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::Wallet;
use QBitcoin::Coins;

$config->{regtest} = 1;
$config->{genesis} = 1;
$config->{genesis_reward} = GENESIS_REWARD;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });

my $static_reward = 200000000;
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { $static_reward });

my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my $pubkey = $pk->pubkey_by_privkey;
my ($address) = addresses_by_pubkey($pubkey, CRYPT_ALGO_ECDSA);
my $myaddr = QBitcoin::MyAddress->create({
    private_key => wallet_import_format($pk->pk_serialize),
    address     => $address,
    staked      => 1,
});

QBitcoin::Coins->init();

my $time = GENESIS_TIME;
block_hash("a0");
my $block0 = QBitcoin::Generate->generate($time);
ok($block0, "Genesis block generated");

# Encrypt the wallet keys; the wallet stays unlocked, so generation still works
is(QBitcoin::Wallet->change_password(undef, "pass1"), undef, "wallet keys encrypted");
ok(QBitcoin::Wallet->signing_available, "signing available while unlocked");

my $stake_tx = send_tx(-$static_reward);
undef $last_tx;
my $tx = send_tx(0);
my $tx2 = send_tx(0, $tx, $myaddr->redeem_script);
send_block(1, "a1", "a0", 5, $stake_tx, $tx, $tx2);
is(QBitcoin::Block->blockchain_height, 1, "Block a1 received");

# A locked wallet cannot sign the stake transaction
QBitcoin::Wallet->lock;
ok(!QBitcoin::Wallet->signing_available, "signing unavailable while locked");
block_hash("b1");
my $block1 = eval { QBitcoin::Generate->generate($time + BLOCK_INTERVAL) };
like($@, qr/Wallet is locked/, "generation fails on the locked wallet");
ok(!$block1, "no block generated while locked");

# Unlock and generate the same block
ok(QBitcoin::Wallet->unlock("pass1"), "wallet unlocked");
$block1 = eval { QBitcoin::Generate->generate($time + BLOCK_INTERVAL) };
diag($@) if $@;
ok($block1, "block generated after unlock");
is(QBitcoin::Block->best_block->hash, "b1", "generated block is the best block");

done_testing();
