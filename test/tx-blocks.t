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
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Test::Send qw(send_block send_tx $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::TXO;
use QBitcoin::Generate;

#$config->{debug} = 1;
$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

blockchain_synced(1);

# height, hash, prev_hash, weight, $tx
send_block(0, "a0", undef, 50, send_tx());
send_block($_, "a$_", "a" . ($_-1), $_*100, send_tx()) foreach (1 .. 10);
send_block(11, "a11", "a10", 1100, send_tx());
$last_tx = undef;
send_block(11, "b11", "a10", 1150, send_tx());
block_hash("b12");
QBitcoin::Generate->generate(GENESIS_TIME + 12 * BLOCK_INTERVAL * FORCE_BLOCKS);
send_block($_, "b$_", "b" . ($_-1), $_*100+50, send_tx()) foreach (13 .. 20);

my $height = QBitcoin::Block->blockchain_height;
my $weight = QBitcoin::Block->best_weight;
my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
my $hash   = $block ? $block->hash : undef;
is($height,   20, "height");
is($hash,  "b20", "hash"  );
is($weight, 2050, "weight");
$block = QBitcoin::Block->best_block(11);
is($block->hash, "b11", "best block at height 11");

done_testing();
