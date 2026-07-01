#! /usr/bin/env perl
use warnings;
use strict;

# End-to-end: two really-signed conflicting stakes (same UTXO, same timeslot, different
# block) are observed; the node detects the equivocation, builds a slashing tx whose
# evidence is verified by re-checking the real signatures, puts it in the mempool, and
# bans the equivocated stake. This exercises the trustless-verification path with real
# cryptography (not the OP_1 stubs used elsewhere).

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Slashing;
use QBitcoin::ProtocolState qw(blockchain_synced);

$config->{regtest} = 1;

my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my ($address) = addresses_by_pubkey($pk->pubkey_by_privkey, CRYPT_ALGO_ECDSA);
my $myaddr = QBitcoin::MyAddress->create({
    private_key => wallet_import_format($pk->pk_serialize),
    address     => $address,
    staked      => 1,
});
my $redeem     = $myaddr->redeem_script;
my $scripthash = $myaddr->scripthash;

my $timeslot = timeslot(GENESIS_TIME + 1000);

# A staked coin owned by our key.
my $coin = QBitcoin::TXO->new_txo({ tx_in => pack("H*", "ab" x 32), num => 0, value => 1000, scripthash => $scripthash, data => "" });
$coin->set_redeem_script($redeem) == 0 or die "set_redeem_script\n";

# Build a stake spending $coin and really sign it over the given block_sign_data.
sub signed_stake {
    my ($prev, $digest) = @_;
    my $bsd = $prev . pack("N", $timeslot) . $digest;
    my $out = QBitcoin::TXO->new_txo({ value => $coin->value, scripthash => $scripthash, data => "" });
    my $stake = QBitcoin::Transaction->new(
        in              => [ { txo => $coin, siglist => [] } ],
        out             => [ $out ],
        fee             => 0,
        tx_type         => TX_TYPE_STAKE,
        block_sign_data => $bsd,
    );
    $stake->sign_transaction; # real signature over the message incl. block_sign_data
    return $stake;
}

# Two conflicting blocks: same coin + timeslot, different block (different digest).
my $stake1 = signed_stake("\x11" x 32, "\xa1" x 32);
my $stake2 = signed_stake("\x22" x 32, "\xb2" x 32);

ok(@{$stake1->in->[0]{siglist}} > 0, "stake1 is really signed");
isnt(unpack("H*", $stake1->hash), unpack("H*", $stake2->hash), "the two signed stakes differ");

# The slashing tx built from them must verify (real signature re-check of the evidence).
my $slash = QBitcoin::Slashing->new_tx($stake1, $stake2);
ok($slash, "slashing tx built from two signed conflicting stakes");
is($slash->validate, 0, "slashing tx validates (evidence signatures re-checked)");
is($slash->out->[0]->value, 900, "owner refunded value minus the 10% fine");

# Detection choreography: observe both, then report builds + injects + bans.
blockchain_synced(1);
is(QBitcoin::Slashing->observe($stake1, $timeslot), undef, "first stake observed, no conflict");
my $other = QBitcoin::Slashing->observe($stake2, $timeslot);
ok($other, "second stake observed -> equivocation detected");

my $built = QBitcoin::Slashing->report_equivocation($stake2, $other);
ok($built, "report_equivocation built a slashing tx");
ok(QBitcoin::Transaction->check_by_hash($built->hash), "slashing tx is in the mempool");
ok(QBitcoin::Slashing->is_banned_stake($stake1, $timeslot), "the equivocated stake is now banned");
ok(QBitcoin::Slashing->is_banned_stake($stake2, $timeslot), "...both conflicting stakes are banned");

done_testing();
