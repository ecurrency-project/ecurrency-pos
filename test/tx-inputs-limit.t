#! /usr/bin/env perl
use warnings;
use strict;

# The number of inputs of a transaction is limited. The limit is out of reach for
# signed inputs (a transaction of them hits MAX_TX_SIZE first), it bounds the inputs
# of the smallest possible size: a slashing transaction carries two stakes and adds an
# input and a refund output of its own to each of their common inputs.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Transaction;
use Bitcoin::Serialized qw(varint varstr);

# A standard transaction of the smallest inputs: an empty siglist and a 1-byte redeem script
sub tx_bytes {
    my ($inputs) = @_;
    return pack("c", TX_TYPE_STANDARD)
        . varint($inputs) . join("", map { pack("N", $_) x 8 . varint(0) . varint(0) . varstr("\x51") } 1 .. $inputs)
        . varint(1) . pack("Q<", 1) . varstr("\x00" x 20) . varstr("");
}

sub deserialize {
    my ($bytes) = @_;
    my $data = Bitcoin::Serialized->new($bytes);
    my $tx = QBitcoin::Transaction->deserialize($data);
    return $tx && $data->length == 0 ? $tx : undef;
}

my $bytes = tx_bytes(MAX_INPUTS_PER_TX);
cmp_ok(length($bytes), '<', MAX_TX_SIZE, "the limit of inputs is reachable within the transaction size");
my $tx = deserialize($bytes);
ok($tx, "transaction with the maximum number of inputs is accepted");
is(scalar @{$tx->in_raw}, MAX_INPUTS_PER_TX, "all its inputs are read");
is(deserialize(tx_bytes(MAX_INPUTS_PER_TX + 1)), undef, "one more input is rejected");

done_testing();
