#! /usr/bin/env perl
use warnings;
use strict;

# A slashing refund is spendable only by the owner's standard transaction:
# - staking it again is consensus-invalid (Transaction::validate);
# - slashing it again is consensus-invalid (Transaction::validate_slashing), so a
#   malicious delegate cannot fabricate conflicting stake signatures on the refund
#   and grind the owner's coins down fine by fine;
# - the generator excludes refunds from stake UTXO selection
#   (Transaction::txo_stakeable), so a slashed node fail-stops instead of
#   building invalid blocks.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM qw(dbh);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Slashing;

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
    my $value = 0;
    $value += $_->value foreach @$coins;
    my $stake = QBitcoin::Transaction->new(
        in              => [ map +{ txo => $_, siglist => [] }, @$coins ],
        out             => [ QBitcoin::TXO->new_txo({ value => $value, scripthash => $scripthash, data => "" }) ],
        fee             => -1, # a real block reward; validate() requires a negative stake fee
        tx_type         => TX_TYPE_STAKE,
        block_sign_data => $prev . pack("N", $slot) . $digest,
    );
    $stake->calculate_hash;
    return $stake;
}

# Register a transaction as confirmed at height 0 so type_by_hash resolves it.
sub confirm {
    my ($tx) = @_;
    $tx->block_height(0);
    $tx->block_time($timeslot);
    $tx->add_to_cache;
    QBitcoin::TXO->save_all($tx->hash, $tx->out);
    return $tx;
}

# --- a real slashing tx whose refund we then try to reuse ---------------------

my $coin   = make_coin(pack("H*", "aa" x 32), 0, 1000);
my $stake1 = make_stake([$coin], "\x11" x 32, "\xa1" x 32);
my $stake2 = make_stake([$coin], "\x22" x 32, "\xb2" x 32);
my $slash  = QBitcoin::Slashing->new_tx($stake1, $stake2);
ok($slash, "slashing tx built from two conflicting stakes");
is($slash->validate, 0, "slashing tx on a plain coin validates");
confirm($slash);

my $refund = $slash->out->[0];
is($refund->value, 900, "refund = value - 10% fine");
$refund->set_redeem_script($script) == 0 or die "set_redeem_script failed\n";

# --- rule 1: a stake spending the refund is invalid ---------------------------

my $restake = make_stake([$refund], "\x33" x 32, "\xc3" x 32);
isnt($restake->validate, 0, "stake spending a slashing refund is rejected");

# control: a stake spending a stake output is still valid
my $parent = confirm(make_stake([make_coin(pack("H*", "bb" x 32), 0, 500)], "\x44" x 32, "\xd4" x 32));
my $stake_out = $parent->out->[0];
$stake_out->set_redeem_script($script) == 0 or die "set_redeem_script failed\n";
my $restake_ok = make_stake([$stake_out], "\x55" x 32, "\xe5" x 32);
is($restake_ok->validate, 0, "stake spending a stake output still validates");

# --- rule 2: a slashing tx spending the refund is invalid ---------------------

# Fabricated equivocation on the refund: the signatures are real evidence of
# double-signing, but the punished input is itself a slashing refund.
my $rs1 = make_stake([$refund], "\x66" x 32, "\xf6" x 32);
my $rs2 = make_stake([$refund], "\x77" x 32, "\xa7" x 32);
my $slash2 = QBitcoin::Slashing->new_tx($rs1, $rs2);
ok($slash2, "builder still assembles a slashing tx on a refund");
isnt($slash2->validate, 0, "slashing tx spending a slashing refund is rejected");

# --- the refund stays spendable by a standard transaction ---------------------

my $std = QBitcoin::Transaction->new(
    in      => [ { txo => $refund, siglist => [] } ],
    out     => [ QBitcoin::TXO->new_txo({ value => 899, scripthash => $scripthash, data => "" }) ],
    fee     => 1,
    tx_type => TX_TYPE_STANDARD,
);
$std->calculate_hash;
is($std->validate, 0, "standard spend of the refund still validates");
is($std->in->[0]{min_rel_time}, STAKE_MATURITY, "...subject to the STAKE_MATURITY lock");

# --- txo_stakeable, the predicate the generator's UTXO selection relies on ----

ok(!QBitcoin::Transaction->txo_stakeable($refund),   "a slashing refund is not stakeable");
ok(QBitcoin::Transaction->txo_stakeable($stake_out), "a stake output is stakeable");
ok(QBitcoin::Transaction->txo_stakeable(make_coin(pack("H*", "ee" x 32), 0, 100)),
    "a coin with unknown (not yet loaded) parent is stakeable");

done_testing();
