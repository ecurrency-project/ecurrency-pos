#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Config qw($config read_config);

my $conf = q(
key1 = value1
key2 = part1 part2 # comment # also comment
key3 = val#with#sharp # comment
key4 = " 1 2 3 "
# line comment

key5 = 'quoted "line"'
key1 = redefined value1
);

read_config(\$conf);

is($config->{key1}, "redefined value1");
is($config->{key2}, "part1 part2");
is($config->{key3}, "val#with#sharp");
is($config->{key4}, " 1 2 3 ");
is($config->{key5}, 'quoted "line"');
is_deeply([$config->get_all("key1")], ['value1', 'redefined value1']);

done_testing();
