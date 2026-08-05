#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;

use QBitcoin::Config;
use QBitcoin::Const;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(script_eval op_pushdata);
use QBitcoin::Script::Util qw(pack_int unpack_int);

$config->{debug} = 0;

my $MAX_INT = (1 << 63) - 1; # 2**63-1, max script int magnitude

# [ value, expected encoded length ]
my @round_trip = (
    [ 0,                    1 ],
    [ 1,                    1 ],
    [ 0x7f,                 1 ],
    [ 0x80,                 2 ],
    [ 0x7fff,               2 ],
    [ 0x8000,               3 ],
    [ 0x7fffff,             3 ],
    [ 0x800000,             4 ],
    [ 0x7fffffff,           4 ],
    [ 0x80000000,           5 ],
    [ (1 << 39) - 1,        5 ],
    [ 1 << 39,              6 ],
    [ (1 << 47) - 1,        6 ],
    [ 1 << 47,              7 ],
    [ MAX_VALUE,            7 ], # all satoshi amounts fit 7 bytes
    [ (1 << 55) - 1,        7 ],
    [ 1 << 55,              8 ],
    [ $MAX_INT,             8 ],
);

foreach my $check (@round_trip) {
    my ($value, $length) = @$check;
    foreach my $n ($value, $value == 0 ? () : -$value) {
        my $packed = pack_int($n);
        is(length($packed), $length, "pack length $n");
        is(unpack_int($packed), $n, "round trip $n");
    }
}

is(pack_int($MAX_INT + 1),    undef, "pack 2**63 fails");
is(pack_int(-$MAX_INT - 1),   undef, "pack -2**63 fails");
is(pack_int(2**64),           undef, "pack float overflow fails");
is(unpack_int("\x00" x 9),    undef, "unpack 9 bytes fails");
is(unpack_int(""),            undef, "unpack empty fails");
is(unpack_int(undef),         undef, "unpack undef fails");

# Script-level arithmetic on 64-bit values
my $val_a = MAX_VALUE;              # 2.1e15, 7-byte encoding
my $val_b = 987_654_321_012_345;
my @scripts_ok = (
    [ add_big  => push_int($val_a) . push_int($val_b) . OP_ADD . push_int($val_a + $val_b) . OP_NUMEQUAL ],
    [ sub_big  => push_int($val_a) . push_int($val_b) . OP_SUB . push_int($val_a - $val_b) . OP_NUMEQUAL ],
    [ neg_big  => push_int(-$val_a) . OP_NEGATE . push_int($val_a) . OP_NUMEQUAL ],
    [ cmp_big  => push_int($val_a) . push_int($val_b) . OP_GREATERTHAN ],
    [ add_max  => push_int($MAX_INT - 1) . OP_1ADD . push_int($MAX_INT) . OP_NUMEQUAL ],
);
my @scripts_fail = (
    [ add_overflow  => push_int($MAX_INT) . push_int(1) . OP_ADD ],
    [ add_overflow2 => push_int($MAX_INT) . push_int($MAX_INT) . OP_ADD . OP_DROP . OP_1 ],
    [ sub_overflow  => push_int(-$MAX_INT) . push_int(1) . OP_SUB ],
    [ inc_overflow  => push_int($MAX_INT) . OP_1ADD ],
    [ dec_overflow  => push_int(-$MAX_INT) . OP_1SUB ],
);

foreach my $check_data (@scripts_ok) {
    my ($name, $script) = @$check_data;
    ok(script_eval([], $script, "", 0), $name);
}
foreach my $check_data (@scripts_fail) {
    my ($name, $script) = @$check_data;
    ok(!script_eval([], $script, "", 0), $name);
}

done_testing();

sub push_int {
    my ($n) = @_;
    return op_pushdata(pack_int($n));
}
