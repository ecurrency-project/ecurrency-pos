#! /usr/bin/env perl
use warnings;
use strict;

# The wallet UTXO registry accessors are used in boolean and numeric context as well as in
# list context: "have we anything to stake with?" gates the re-generation trigger on an
# incoming paid transaction (QBitcoin::Protocol::process_tx), the default value of the
# "generate" option (QBitcoin::Network) and the produce limits (QBitcoin::Produce).
#
# Returning the bare list "values(%a), values(%b)" made those checks read the comma operator
# in scalar context, which yields only its LAST element - the size of the second hash. A node
# staking its OWN coins with no delegations therefore counted as having no stake sources at
# all, and never re-generated its block for the current slot when a paid transaction arrived:
# the slot was left to whatever peer did include the transaction, however small its stake.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Wallet::UTXO qw(
    myutxo_add myutxo_del myutxo_list myutxo_staked myutxo_delegated
    UTXO_MY UTXO_STAKED UTXO_DELEGATED
);

{
    package FakeTXO;
    sub new        { bless { key => $_[1] }, $_[0] }
    sub key        { $_[0]->{key} }
    sub tx_in_str  { $_[0]->{key} }
    sub num        { 0 }
    sub value      { 100 }
}

my $own      = FakeTXO->new("own");
my $staked   = FakeTXO->new("staked");
my $delegate = FakeTXO->new("delegated");

myutxo_add($own,    UTXO_MY);
myutxo_add($staked, UTXO_STAKED);

# No delegations: the own staked coin must be visible in every context.
is(scalar(my @s1 = myutxo_staked()), 1, "one stake source in list context");
ok(myutxo_staked(), "...and it is true in boolean context");
is(scalar(myutxo_staked()), 1, "...and counts as one in numeric context");

is(scalar(my @l1 = myutxo_list()), 2, "own and staked coins in list context");
is(scalar(myutxo_list()), 2, "...and both are counted in numeric context");

myutxo_add($delegate, UTXO_DELEGATED);
is(scalar(my @s2 = myutxo_staked()), 2, "delegated coin joins the stake sources");
is(scalar(myutxo_staked()), 2, "...and is counted too");
is(scalar(myutxo_delegated()), 1, "only the delegated coin is delegated");
is(scalar(myutxo_list()), 2, "...and it is not our money, so not in the wallet list");

myutxo_del($staked);
ok(myutxo_staked(), "still have a stake source while only the delegated coin is left");
myutxo_del($delegate);
ok(!myutxo_staked(), "no stake sources at all is false");
ok(myutxo_list(), "...while the own coin is still in the wallet");

done_testing();
