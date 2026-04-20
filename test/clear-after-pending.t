#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(send_block send_tx $connection $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
$config->{regtest} = 1;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

blockchain_synced(1);

my $start_tx = send_tx();
my $pending_tx = make_tx(0, undef);
send_block(0, "a0", undef, 50, $start_tx);
send_block(1, "a1", "a0", 52, send_tx(0, $start_tx));

send_block(2, "a2", "a1", 61, $pending_tx);
send_block(2, "b2", "b1", 60, $pending_tx);

send_block(1, "b1", "a0", 51, send_tx(0, $start_tx));

$connection->protocol->command("tx");
$connection->protocol->cmd_tx($pending_tx->serialize . "\x00"x16);

my $block = QBitcoin::Block->best_block();
is($block->hash, "a2", "Best block is a2");

done_testing();
