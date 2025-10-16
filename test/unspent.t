#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::Send qw(make_block send_block send_tx $connection $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Block;
use QBitcoin::Revalidate qw(revalidate);
use QBitcoin::Address qw(address_by_hash);
use QBitcoin::Utils qw(get_address_utxo);

#$config->{debug} = 1;
$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });

send_block(0, "a0", undef, 1, send_tx());
my $stake = send_tx(-1);
my $tx = send_tx(1, undef);

send_block(1, "a1", "a0", 52, $stake, $tx);
foreach my $height (2 .. 10) {
    send_block($height, "a$height", "a" . ($height-1), 50 + $height*2, send_tx());
}

QBitcoin::Block->store_blocks();
QBitcoin::Block->cleanup_old_blocks();

pass("Blocks stored successfully");

my $block = QBitcoin::Block->find(hash => "a1");
$block->transactions;

my $txo = QBitcoin::TXO->get({ tx_out => $tx->hash, num => 0 });
is($txo->unspent, 0, "Transaction output is marked as spent");

my ($chain_utxo, $mempool_utxo) = get_address_utxo(address_by_hash($tx->out->[0]->scripthash));
my @txid = (keys(%$chain_utxo), keys(%$mempool_utxo));
is(scalar @txid, 0, "No UTXO found for the transaction");

done_testing();
