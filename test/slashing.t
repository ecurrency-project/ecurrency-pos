#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM qw(dbh);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(hash160 hash256);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Block;
use QBitcoin::Slashing;
use QBitcoin::Slashing::Stored;
use Bitcoin::Serialized;

$config->{regtest} = 1;

# anyone-can-spend script: no signature needed, keeps the test key-free
my $script     = op_pushdata(pack("v", 1)) . OP_DROP . OP_1;
my $scripthash = hash160($script);
my $timeslot   = timeslot(GENESIS_TIME + 1000);

sub make_coin {
    my ($txid, $num, $value) = @_;
    my $txo = QBitcoin::TXO->new_txo({ tx_in => $txid, num => $num, value => $value, scripthash => $scripthash, data => "" });
    $txo->set_redeem_script($script) == 0 or die "set_redeem_script failed\n";
    return $txo;
}

sub make_stake {
    my ($coins, $prev, $digest, $slot) = @_;
    $slot //= $timeslot;
    my $bsd = $prev . pack("N", $slot) . $digest;
    my $value = 0;
    $value += $_->value foreach @$coins;
    my $stake = QBitcoin::Transaction->new(
        in              => [ map +{ txo => $_, siglist => [] }, @$coins ],
        out             => [ QBitcoin::TXO->new_txo({ value => $value, scripthash => $scripthash, data => "" }) ],
        fee             => 0,
        tx_type         => TX_TYPE_STAKE,
        block_sign_data => $bsd,
    );
    $stake->calculate_hash;
    return $stake;
}

# Two conflicting stakes: same UTXO, same timeslot, different block.
my $coin   = make_coin(pack("H*", "aa" x 32), 0, 1000);
my $stake1 = make_stake([$coin], "\x11" x 32, "\xa1" x 32);
my $stake2 = make_stake([$coin], "\x22" x 32, "\xb2" x 32);

my $slash = QBitcoin::Slashing->new_tx($stake1, $stake2);
ok($slash, "slashing tx built from two conflicting stakes");
is($slash->tx_type, TX_TYPE_SLASHING, "tx_type is slashing");
is(scalar @{$slash->in},  1, "one slashed input");
is(scalar @{$slash->out}, 1, "one refund output");
is($slash->out->[0]->value, 900, "refund = value - 10% fine");
is($slash->fee, 100, "fine (10%) becomes the fee");

is($slash->validate, 0, "slashing tx validates");

# wire round-trip is byte-stable
my $data   = Bitcoin::Serialized->new($slash->serialize);
my $slash2 = QBitcoin::Transaction->deserialize($data);
ok($slash2, "deserialized");
is($data->length, 0, "all bytes consumed");
is(unpack("H*", $slash2->hash), unpack("H*", $slash->hash), "hash is stable over serialize/deserialize");
is($slash2->tx_type, TX_TYPE_SLASHING, "deserialized type is slashing");
ok($slash2->slashing, "deserialized evidence present");

# tampering the refund must invalidate
my $bad = QBitcoin::Slashing->new_tx($stake1, $stake2);
$bad->out->[0]->{value} = 950;
isnt($bad->validate, 0, "tampered refund value is rejected");

# same block (identical block_sign_data) is not equivocation
my $stake1b = make_stake([$coin], "\x11" x 32, "\xa1" x 32);
is(QBitcoin::Slashing->new_tx($stake1, $stake1b), undef, "no slashing when both stakes sign the same block");

# different timeslot is not equivocation
my $stake_late = make_stake([$coin], "\x22" x 32, "\xb2" x 32, $timeslot + BLOCK_INTERVAL);
is(QBitcoin::Slashing->new_tx($stake1, $stake_late), undef, "no slashing across different timeslots");

# no shared UTXO is not equivocation
my $coin2  = make_coin(pack("H*", "cc" x 32), 0, 1000);
my $stake3 = make_stake([$coin2], "\x22" x 32, "\xb2" x 32);
is(QBitcoin::Slashing->new_tx($stake1, $stake3), undef, "no slashing without a shared stake UTXO");

# partial overlap: only the shared UTXO is slashed
my $coinA  = make_coin(pack("H*", "d1" x 32), 0, 1000);
my $coinB  = make_coin(pack("H*", "d2" x 32), 0, 2000);
my $coinC  = make_coin(pack("H*", "d3" x 32), 0, 4000);
my $stakeX = make_stake([$coinA, $coinB], "\x11" x 32, "\xa1" x 32);
my $stakeY = make_stake([$coinB, $coinC], "\x22" x 32, "\xb2" x 32);
my $slashP = QBitcoin::Slashing->new_tx($stakeX, $stakeY);
ok($slashP, "slashing built for partial overlap");
is(scalar @{$slashP->in}, 1, "only the shared UTXO is slashed");
is($slashP->in->[0]->{txo}->value, 2000, "shared UTXO is the overlapping one");
is($slashP->validate, 0, "partial-overlap slashing validates");

# weight: a slashing tx contributes the same age-weighted weight as a stake spending
# the same UTXOs, so it can outweigh the stake it punishes.
{
    my $mock = Test::MockModule->new('QBitcoin::Transaction');
    my $in_time = $timeslot - 100000 * BLOCK_INTERVAL;
    $mock->mock('txo_time', sub { return $in_time });
    my $block = QBitcoin::Block->new({ time => $timeslot });
    is($slash->slashing_weight($timeslot), $stake1->stake_weight($block),
        "slashing weight equals stake weight for the same inputs and age");
    ok($slash->slashing_weight($timeslot) > 0, "slashing weight is positive");
}

# persistence: evidence survives a store/load round-trip and rebuilds the same tx.
# Insert the row in isolation (no parent transaction row here), so drop the FK check.
my $blob = $slash->slashing->serialize;
dbh->do("PRAGMA foreign_keys = OFF");
QBitcoin::Slashing::Stored->create({ tx_id => 1, evidence => $blob });
my ($row) = QBitcoin::Slashing::Stored->find(tx_id => 1);
ok($row, "stored evidence row found");
is(unpack("H*", $row->evidence), unpack("H*", $blob), "stored evidence bytes match");
my $ev = QBitcoin::Slashing->deserialize(Bitcoin::Serialized->new($row->evidence));
my $rebuilt = QBitcoin::Transaction->new(
    in       => $slash->in,
    out      => $slash->out,
    fee      => $slash->fee,
    tx_type  => TX_TYPE_SLASHING,
    slashing => $ev,
);
$rebuilt->calculate_hash;
is(unpack("H*", $rebuilt->hash), unpack("H*", $slash->hash), "tx rebuilt from stored evidence has the same hash");

done_testing();
