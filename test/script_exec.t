#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;

use QBitcoin::Config;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(script_eval op_pushdata);

$config->{debug} = 0;

my @scripts_ok = (
    [ op_verify_1 => OP_1 . OP_VERIFY ],
    [ op_nested   => op_pushdata(OP_1) . OP_EXEC . OP_VERIFY ],
);

my @scripts_fail = (
    [ op_1        => OP_1 ],
    [ op_verify   => OP_0 . OP_VERIFY ],
    [ op_nested   => op_pushdata(OP_0) . OP_EXEC . OP_VERIFY ],
    [ op_infinite => op_pushdata(OP_DUP . OP_EXEC) . OP_DUP . OP_EXEC ],
);

foreach my $check_data (@scripts_ok) {
    my ($name, $script) = @$check_data;
    my $res = script_eval([$script], OP_EXEC . OP_1, "", 0);
    ok($res, $name);
}

foreach my $check_data (@scripts_fail) {
    my ($name, $script, $tx_data) = @$check_data;
    my $res = script_eval([$script], OP_EXEC . OP_1, "", 0);
    ok(!$res, $name);
}

done_testing();
