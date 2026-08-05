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
use QBitcoin::Script::Util qw(pack_int);

$config->{debug} = 0;

my $sh_deleg = "\xd1" x 20; # delegated address, spent by input 0
my $sh_other = "\x22" x 20;
my $sh_none  = "\x33" x 20; # not present in the transaction

# Values above 2**39 to exercise 64-bit script ints
my $v1 = 1 << 41;
my $v2 = 1 << 42;
my $v3 = 12_345_678_901;

my $tx = TestTx->new(
    in  => [
        { txo => TestTxo->new(scripthash => $sh_deleg, value => $v1) },
        { txo => TestTxo->new(scripthash => $sh_deleg, value => $v2) },
        { txo => TestTxo->new(scripthash => $sh_other, value => $v3) },
    ],
    out => [
        TestTxo->new(scripthash => $sh_deleg, value => $v1),
        TestTxo->new(scripthash => $sh_deleg, value => $v2),
        TestTxo->new(scripthash => $sh_other, value => $v3 - 100),
    ],
);

# The delegated-staking covenant: outputs to my own scripthash must be
# not less than the inputs spent from it.
my $covenant = OP_INPUTSCRIPTHASH . OP_DUP . OP_OUTPUTSVALUE . OP_SWAP . OP_INPUTSVALUE . OP_GREATERTHANOREQUAL;

my @scripts_ok = (
    [ inputscripthash => OP_INPUTSCRIPTHASH . op_pushdata($sh_deleg) . OP_EQUALVERIFY . OP_1 ],
    [ inputsvalue     => op_pushdata($sh_deleg) . OP_INPUTSVALUE . op_pushdata(pack_int($v1 + $v2)) . OP_NUMEQUAL ],
    [ inputsvalue2    => op_pushdata($sh_other) . OP_INPUTSVALUE . op_pushdata(pack_int($v3)) . OP_NUMEQUAL ],
    [ inputsvalue0    => op_pushdata($sh_none) . OP_INPUTSVALUE . op_pushdata(pack_int(0)) . OP_NUMEQUAL ],
    [ outputsvalue    => op_pushdata($sh_deleg) . OP_OUTPUTSVALUE . op_pushdata(pack_int($v1 + $v2)) . OP_NUMEQUAL ],
    [ outputsvalue0   => op_pushdata($sh_none) . OP_OUTPUTSVALUE . op_pushdata(pack_int(0)) . OP_NUMEQUAL ],
    [ memoized        => op_pushdata($sh_deleg) . OP_OUTPUTSVALUE . op_pushdata($sh_deleg) . OP_OUTPUTSVALUE . OP_NUMEQUAL ],
    [ covenant_hold   => $covenant ],
);

my @scripts_fail = (
    [ inputsvalue_empty  => OP_INPUTSVALUE ],
    [ outputsvalue_empty => OP_OUTPUTSVALUE ],
);

foreach my $check_data (@scripts_ok) {
    my ($name, $script) = @$check_data;
    ok(script_eval([], $script, $tx, 0), $name);
}
foreach my $check_data (@scripts_fail) {
    my ($name, $script) = @$check_data;
    ok(!script_eval([], $script, $tx, 0), $name);
}

# Covenant runs identically for every input spending the delegated scripthash
ok(script_eval([], $covenant, $tx, 1), "covenant input 1");
# ... but does not hold for the input whose scripthash loses value
ok(!script_eval([], $covenant, $tx, 2), "covenant broken for other input");

# Theft attempt: the delegated principal is redirected to another address
my $tx_steal = TestTx->new(
    in  => [ { txo => TestTxo->new(scripthash => $sh_deleg, value => $v1) } ],
    out => [
        TestTxo->new(scripthash => $sh_deleg, value => $v1 - 1),
        TestTxo->new(scripthash => $sh_other, value => 1),
    ],
);
ok(!script_eval([], $covenant, $tx_steal, 0), "covenant catches theft");

# No outputs to the delegated scripthash at all
my $tx_steal_all = TestTx->new(
    in  => [ { txo => TestTxo->new(scripthash => $sh_deleg, value => $v1) } ],
    out => [ TestTxo->new(scripthash => $sh_other, value => $v1) ],
);
ok(!script_eval([], $covenant, $tx_steal_all, 0), "covenant catches full theft");

done_testing();

package TestTx;
use warnings;
use strict;
use QBitcoin::Accessors qw(new);
sub in  { $_[0]->{in} }
sub out { $_[0]->{out} }

package TestTxo;
use warnings;
use strict;
use QBitcoin::Accessors qw(new);
sub scripthash { $_[0]->{scripthash} }
sub value      { $_[0]->{value} }

1;
