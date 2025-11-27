#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Test::Send qw(send_tx send_block);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Transaction;
use QBitcoin::Block;
use QBitcoin::Generate;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;

#$config->{debug} = 1;
$config->{regtest} = 1;
$config->{genesis} = 1;
$config->{genesis_reward} = GENESIS_REWARD;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });

my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my $pubkey = $pk->pubkey_by_privkey;
my ($address) = addresses_by_pubkey($pubkey, CRYPT_ALGO_ECDSA);
my $myaddr = QBitcoin::MyAddress->create({
    private_key => wallet_import_format($pk->pk_serialize),
    address     => $address,
});

my $time = GENESIS_TIME;
block_hash("a0");
my $block0 = QBitcoin::Generate->generate($time);
ok($block0, "Genesis block generated");

my $tx = send_tx();
my $tx2 = send_tx(0, $tx, $myaddr->redeem_script);
send_block(1, "a1", "a0", 5, $tx, $tx2);
is(QBitcoin::Block->blockchain_height, 1, "Block 1 received");

block_hash("b1");
my $block1 = eval { QBitcoin::Generate->generate($time + BLOCK_INTERVAL) };
ok($block1, "Alternative block 1 generated");
is(scalar(@{$block1->transactions}), 2, "Generated block conrains 2 transactions");
is(QBitcoin::Block->best_block->hash, "b1", "Block 1 altered");

done_testing();
