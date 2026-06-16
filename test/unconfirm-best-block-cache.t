#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Block;
use QBitcoin::Const;

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('validate', sub { 0 });

my $block0 = QBitcoin::Block->new(
    height       => 0,
    time         => GENESIS_TIME,
    hash         => "genesis-block",
    transactions => [],
    weight       => 1,
);
$block0->receive;

my $block1 = QBitcoin::Block->new(
    height       => 1,
    time         => GENESIS_TIME + BLOCK_INTERVAL,
    hash         => "generated-block",
    prev_hash    => $block0->hash,
    prev_block   => $block0,
    transactions => [],
    weight       => 1,
);
$block1->receive;

is(QBitcoin::Block->blockchain_height, 1, "generated block is the best tip");
is(QBitcoin::Block->best_block(1)->hash, $block1->hash, "best block is cached at height 1");

$block1->unconfirm;

is(QBitcoin::Block->blockchain_height, 0, "best height moved back after unconfirm");
is(QBitcoin::Block->best_block(1), undef, "unconfirmed block is removed from best-block cache");

done_testing();
