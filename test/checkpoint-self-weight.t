#! /usr/bin/env perl
use warnings;
use strict;

# The weight of a block received below the last checkpoint (partial validation) or loaded
# from the database is taken from its header: the chain there is settled or was verified
# when stored, and the rules may have changed since. A block received under the full
# validation, or a block we generate ourselves (no header weight yet), gets its weight
# from its contents.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Block;
use QBitcoin::ProtocolState qw(skip_scripts);

$config->{regtest} = 1;


my $prev = QBitcoin::Block->new(height => 0, time => GENESIS_TIME, weight => 100, transactions => []);
# a non-forced slot, so no forced-block weight bonus
my $time = GENESIS_TIME + BLOCK_INTERVAL;

my $peer = 1; # stands for the protocol object the block was received from

skip_scripts(1);
my $below = QBitcoin::Block->new(height => 1, time => $time, weight => 300, prev_block => $prev, received_from => $peer, transactions => []);
is($below->self_weight, 200, "block received under partial validation: weight from the header");

skip_scripts(0);
my $loaded = QBitcoin::Block->new(height => 1, time => $time, weight => 300, prev_block => $prev, transactions => []);
is($loaded->self_weight, 200, "block loaded from the database: weight from the header");

my $received = QBitcoin::Block->new(height => 1, time => $time, weight => 300, prev_block => $prev, received_from => $peer, transactions => []);
is($received->self_weight, 0, "block received under full validation: weight from the contents");

my $generated = QBitcoin::Block->new(height => 1, time => $time, prev_block => $prev, transactions => []);
is($generated->self_weight, 0, "generated block: weight from the contents");

done_testing();
