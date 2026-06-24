#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Const;
use QBitcoin::Generate::Control;

# Randomized in-slot generation delay: gen_time($slot) = $slot + BLOCK_INTERVAL*(1-sqrt(rand)),
# chosen once per slot. Used by the main loop to wait a bit (unpredictably) after the slot
# start before producing the block.

my $C    = 'QBitcoin::Generate::Control';
my $slot = 1000;

my $t = $C->gen_time($slot);
ok($t > $slot && $t < $slot + BLOCK_INTERVAL, "gen_time falls strictly inside the slot");
is($C->gen_time($slot), $t, "memoized: same slot returns the same moment");

my $t2 = $C->gen_time($slot + BLOCK_INTERVAL);
ok($t2 > $slot + BLOCK_INTERVAL && $t2 < $slot + 2 * BLOCK_INTERVAL,
    "a new slot re-rolls a fresh moment inside that slot");

# Distribution: small delays should dominate. E[1 - sqrt(U)] = 1 - 2/3 = 1/3 of the slot.
my $n   = 5000;
my $s   = 100000;
my $sum = 0;
my $first_quarter = 0;
for (1 .. $n) {
    my $d = $C->gen_time($s) - $s;
    $sum += $d;
    $first_quarter++ if $d < BLOCK_INTERVAL / 4;
    $s += BLOCK_INTERVAL;
}
my $mean = $sum / $n / BLOCK_INTERVAL;
ok($mean > 0.27 && $mean < 0.40, "mean delay is about 1/3 of the slot (got $mean)");
# P(d < BI/4) = 1 - (1 - 1/4)^2 = 1 - 9/16 = 7/16 ~ 0.44 -> small delays are common
ok($first_quarter / $n > 0.35, "small delays (< quarter slot) are common");

done_testing();
