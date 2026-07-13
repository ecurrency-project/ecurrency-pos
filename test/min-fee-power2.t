#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::MinFee qw(min_fee MIN_FEE);

# Unit test for min_fee() around the FEE_LINEAR_SIZE boundary,
# especially prev_size == 0 (forced empty block) where the size delta
# can reach exactly FEE_LINEAR_SIZE and index the last @POWER2 element

package MockBlock;
sub new     { my ($class, $min_fee, $size) = @_; return bless { min_fee => $min_fee, size => $size }, $class }
sub min_fee { $_[0]->{min_fee} }
sub size    { $_[0]->{size} }

package main;

my $warnings = 0;
local $SIG{__WARN__} = sub { $warnings++; diag("warning: $_[0]") };

my $empty = MockBlock->new(0, 0);

# Exponential part: min_fee doubles for each 16KB increase, so +32KB gives x4
is(min_fee($empty, 32768), MIN_FEE * 4, "prev_size=0, size=32768: min_fee is MIN_FEE * 4");
is(min_fee($empty, 32767), 39, "prev_size=0, size=32767: last but one POWER2 element");
# Linear part above FEE_LINEAR_SIZE: x4 for the first 32KB, then proportional
is(min_fee($empty, 32769), MIN_FEE * 4, "prev_size=0, size=32769: linear part rounds down to MIN_FEE * 4");
is(min_fee($empty, 65536), MIN_FEE * 8, "prev_size=0, size=65536: exponential then linear x2");
is(min_fee($empty, 1048576), MIN_FEE * 4 * 32, "prev_size=0, size=1MB: exponential then linear x32");

# Small non-zero prev_size still hits high POWER2 indexes
is(min_fee(MockBlock->new(MIN_FEE, 64), 32768), 39, "prev_size=64, size=32768: index 511");

# Decrease path is unaffected
is(min_fee(MockBlock->new(MIN_FEE, 32768), 256), MIN_FEE, "size decrease keeps MIN_FEE floor");

is($warnings, 0, "no uninitialized value warnings");

done_testing();
