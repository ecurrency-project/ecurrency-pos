#! /usr/bin/env perl
use warnings;
use strict;

use Test::More;
use FindBin '$Bin';
use File::Find;

eval "require Perl::Critic" or do { ## no critic (BuiltinFunctions::ProhibitStringyEval)
    plan skip_all => "Perl::Critic is not installed";
    exit;
};

my $critic = Perl::Critic->new(-severity => 5, -profile => "$Bin/../.perlcriticrc");
my @violations;

sub check_file {
    return unless -f $_;
    return if /^\..*swp$/;
    my $file = substr($File::Find::name, 2); # remove leading './'
    push @violations, map { "$file $_" } $critic->critique($_);
}
chdir "$Bin/../lib" or die "Cannot chdir to $Bin/../lib: $!";
find(\&check_file, ".");
chdir "$Bin/../bin" or die "Cannot chdir to $Bin/../bin: $!";
find(\&check_file, ".");
chdir "$Bin/../test" or die "Cannot chdir to $Bin/../test: $!";
find(\&check_file, ".");

is(scalar @violations, 0, 'No Perl::Critic violations')
    or diag("Violations:\n" . join('', @violations));

done_testing();
