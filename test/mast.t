#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;

use QBitcoin::Config;
use QBitcoin::Crypto qw(hash256);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(script_eval op_pushdata);

$config->{debug} = 0;

my @hashes = map { pack("H*", $_ x 64) } ( 1 .. 8 );
my @merkle_l1 = (hash256( $hashes[0] . $hashes[1] ), hash256( $hashes[2] . $hashes[3] ), hash256( $hashes[4] . $hashes[5] ), hash256( $hashes[6] . $hashes[7] ));
my @merkle_l2 = ( hash256( $merkle_l1[0] . $merkle_l1[1] ), hash256( $merkle_l1[2] . $merkle_l1[3] ) );
my $merkle_root = hash256( $merkle_l2[0] . $merkle_l2[1] );

my @ok = (
    [ "1"x64 => $hashes[1] . $merkle_l1[1] . $merkle_l2[1] ],
    [ "2"x64 => $hashes[0] . $merkle_l1[1] . $merkle_l2[1] ],
    [ "3"x64 => $hashes[3] . $merkle_l1[0] . $merkle_l2[1] ],
    [ "4"x64 => $hashes[2] . $merkle_l1[0] . $merkle_l2[1] ],
    [ "5"x64 => $hashes[5] . $merkle_l1[3] . $merkle_l2[0] ],
    [ "6"x64 => $hashes[4] . $merkle_l1[3] . $merkle_l2[0] ],
    [ "7"x64 => $hashes[7] . $merkle_l1[2] . $merkle_l2[0] ],
    [ "8"x64 => $hashes[6] . $merkle_l1[2] . $merkle_l2[0] ],
);

my @fail = (
    [ "1"x64 => $hashes[1] . $merkle_l1[1] . $merkle_l2[0] ],
    [ "3"x64 => $hashes[0] . $merkle_l1[1] . $merkle_l2[0] ],
    [ "4"x62 => $hashes[2] . $merkle_l1[0] . $merkle_l2[1] ],
    [ ""     => $hashes[2] . $merkle_l1[0] . $merkle_l2[1] ],
    [ "5"x64 => "" ],
    [ "6"x64 => $hashes[4] . $merkle_l1[3] . $merkle_l2[0] . "\x01" ],
    [ "7"x32 => $hashes[7] . $merkle_l1[2] . $merkle_l2[0] ],
);

my $script = op_pushdata($merkle_root) . OP_MASTVERIFY . OP_1;

foreach my $check_data (@ok) {
    my $res = script_eval([pack("H*", $check_data->[0]), $check_data->[1]], $script, "", 0);
    ok($res);
}

foreach my $check_data (@fail) {
    my $res = script_eval([pack("H*", $check_data->[0]), $check_data->[1]], $script, "", 0);
    ok(!$res);
}

my $res = script_eval([pack("H*", "1"x64)], $script, "", 0);
ok(!$res);

done_testing();
