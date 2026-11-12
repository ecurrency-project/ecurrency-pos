#! /usr/bin/env perl
use warnings;
use strict;

# A slashing transaction carries the two stake transactions it punishes, so it is
# allowed to be larger than any other transaction. The limits are chosen so that two
# stakes of any allowed size and number of inputs are always punishable: the slashing
# transaction for them fits its own size limit and a block with any stake transaction.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(hash256);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Slashing;
use Bitcoin::Serialized;

$config->{regtest} = 1;

my $timeslot = timeslot(GENESIS_TIME + 1000);

# Two stakes of the same $inputs coins for different blocks, and their slashing
# transaction. Each coin has its own anyone-can-spend script of about $script_size
# bytes at a 32-byte address and is the output number $num of its transaction.
sub double_stake {
    my ($inputs, $script_size, $num) = @_;
    my @coins = map {
        my $script = op_pushdata(pack("n", $_) . "x" x ($script_size - 6)) . OP_DROP . OP_1;
        my $coin = QBitcoin::TXO->new_txo({ tx_in => pack("N", $_) x 8, num => $num, value => 1000, scripthash => hash256($script) });
        $coin->set_redeem_script($script) == 0 or die "set_redeem_script failed\n";
        $coin
    } 1 .. $inputs;
    my @stakes = map {
        my $stake = QBitcoin::Transaction->new(
            in              => [ map +{ txo => $_, siglist => [] }, @coins ],
            out             => [ QBitcoin::TXO->new_txo({ value => 1000 * $inputs, scripthash => "\x00" x 20 }) ],
            fee             => 0,
            tx_type         => TX_TYPE_STAKE,
            block_sign_data => $_->[0] . pack("N", $timeslot) . $_->[1],
        );
        $stake->calculate_hash;
        $stake
    } [ "\x11" x 32, "\xa1" x 32 ], [ "\x22" x 32, "\xb2" x 32 ];
    return (QBitcoin::Slashing->new_tx(@stakes), @stakes);
}

sub deserialize {
    my ($tx) = @_;
    my $data = Bitcoin::Serialized->new($tx->serialize);
    my $res = QBitcoin::Transaction->deserialize($data);
    return $res && $data->length == 0 ? $res : undef;
}

# --- what the slashing transaction adds to its two stakes: the largest when all their
# inputs are shared and every one is refunded to its own 32-byte address
use constant {
    PER_INPUT => 37 + 42, # its input (no siglist, no redeem script) and the refund output
    PER_TX    => 163,     # the rest: type, block sign data, lengths
};
{
    my $inputs = 300;
    my ($slash, $stake) = double_stake($inputs, 8, 300);
    is($slash->validate, 0, "slashing tx of $inputs inputs validates");
    is(scalar @{$slash->out}, $inputs, "every input is refunded separately");
    my $added = $slash->size - 2 * $stake->size;
    cmp_ok($added, '<=', PER_INPUT * $inputs + PER_TX, "it adds up to " . PER_INPUT . " bytes for an input to its stakes");
    cmp_ok($added, '>', PER_INPUT * $inputs, "...and not less in the worst case");
}
my $max_size = 2 * MAX_TX_SIZE + PER_INPUT * MAX_INPUTS_PER_TX + PER_TX;
cmp_ok($max_size, '<=', MAX_SLASHING_TX_SIZE, "slashing transaction for any two stakes fits its size limit");
cmp_ok($max_size + MAX_TX_SIZE, '<=', MAX_BLOCK_SIZE, "...and a block with any stake transaction");

# --- larger than any other transaction may be
{
    my ($slash, $stake) = double_stake(18, 60000, 0);
    cmp_ok($stake->size, '<=', MAX_TX_SIZE, "a stake of " . $stake->size . " bytes is allowed");
    cmp_ok($slash->size, '>', MAX_TX_SIZE, "its slashing tx of " . $slash->size . " bytes is larger than MAX_TX_SIZE");
    is($slash->validate, 0, "...is valid");
    my $received = deserialize($slash);
    ok($received, "...and is accepted from the wire");
    is($received && $received->hash, $slash->hash, "...the same transaction");
}

# --- the size limit holds for a slashing transaction the node builds itself as well: it
# is not deserialized, but peers have to receive it. Stakes within their own limits never
# make such a transaction (see above), so its size is just set here.
{
    my ($slash) = double_stake(2, 8, 0);
    $slash->size = MAX_SLASHING_TX_SIZE;
    is($slash->validate, 0, "built slashing tx of the maximum size is valid");
    $slash->size = MAX_SLASHING_TX_SIZE + 1;
    isnt($slash->validate, 0, "built slashing tx over the size limit is not");
}

done_testing();
