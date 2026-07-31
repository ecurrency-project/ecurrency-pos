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
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(generate_keypair hash256);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Block;
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

# --- the slashing tx in the mempool: choose_for_block filters by min_tx_time /
# min_tx_block_height, which lazily call check_input_script. Slashing inputs are spent
# without a signature (and the txo may have no redeem_script revealed), so no input
# script must be evaluated (regression: substr on undef script in Script::State).
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    is($built->min_tx_time, -1, "slashing tx min_tx_time is unlimited");
    is($built->min_tx_block_height, -1, "slashing tx min_tx_block_height is unlimited");
    is("@warnings", "", "no perl warnings evaluating slashing tx timelocks");
}

# --- a block carrying the slashing tx (regression: Block::Validate had no branch for
# TX_TYPE_SLASHING, so the node's own generated block failed validation and died).
# Non-regtest mode also enforces the fixed tx order: stake, coinbase, slashing, standard.
$config->{regtest} = 0; # GENESIS_HASH is empty, so the genesis hash check stays off

my $block_time = $timeslot + BLOCK_INTERVAL;

# A fresh staked coin for the block's own (non-equivocated) stake.
my $coin2 = QBitcoin::TXO->new_txo({ tx_in => pack("H*", "cd" x 32), num => 0, value => 1000, scripthash => $scripthash, data => "" });
$coin2->set_redeem_script($redeem) == 0 or die "set_redeem_script\n";

# Genesis-height block: block reward is GENESIS_REWARD, consumed by the stake.
sub block_with {
    my (@rest) = @_; # non-stake transactions, in block order
    my $tx_hashes = join("", map { $_->hash } @rest);
    my $bsd = ZERO_HASH . pack("N", timeslot($block_time)) . hash256($tx_hashes);
    my $out = QBitcoin::TXO->new_txo({ value => $coin2->value + GENESIS_REWARD, scripthash => $scripthash, data => "" });
    my $stake = QBitcoin::Transaction->new(
        in              => [ { txo => $coin2, siglist => [] } ],
        out             => [ $out ],
        fee             => -GENESIS_REWARD,
        tx_type         => TX_TYPE_STAKE,
        block_sign_data => $bsd,
        received_time   => time(),
    );
    $stake->sign_transaction;
    my $block = QBitcoin::Block->new(
        height       => 0,
        time         => $block_time,
        weight       => 0,
        transactions => [ $stake, @rest ],
    );
    $block->merkle_root = $block->calculate_merkle_root;
    $block->hash = $block->calculate_hash;
    return $block;
}

is(block_with($built)->validate, "", "block with stake + slashing tx validates");

# A zero-fee standard tx to probe the ordering rule (input scripts of standard txs are
# not evaluated by block validate; preset timelocks to skip the lazy script check).
my $coin3 = QBitcoin::TXO->new_txo({ tx_in => pack("H*", "ef" x 32), num => 0, value => 500, scripthash => $scripthash, data => "" });
$coin3->set_redeem_script($redeem) == 0 or die "set_redeem_script\n";
my $std = QBitcoin::Transaction->new(
    in            => [ { txo => $coin3, siglist => [] } ],
    out           => [ QBitcoin::TXO->new_txo({ value => 500, scripthash => $scripthash, data => "" }) ],
    fee           => 0,
    tx_type       => TX_TYPE_STANDARD,
    received_time => time(),
);
$std->{min_tx_time} = -1;
$std->{min_tx_block_height} = -1;
$std->calculate_hash;

is(block_with($built, $std)->validate, "", "block ordered stake, slashing, standard validates");
like(block_with($std, $built)->validate, qr/must not be after standard/,
    "slashing tx after a standard tx is rejected");

$config->{regtest} = 1;

done_testing();
