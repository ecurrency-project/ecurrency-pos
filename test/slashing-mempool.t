#! /usr/bin/env perl
use warnings;
use strict;

# A slashing transaction is kept in the mempool despite its "already spent" input only
# while we can still free that input by dropping the equivocated block - that is, while
# the spender is confirmed in the levels we hold in memory. Once the spend is confirmed
# below them it can never be undone here and the transaction must leave the mempool
# instead of hanging there forever. While it is there it must also not make us stake a
# sibling block in every slot.

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
use QBitcoin::Block;
use QBitcoin::Slashing;
use QBitcoin::Generate;

$config->{regtest} = 1;

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
        fee             => 0,
        tx_type         => TX_TYPE_STAKE,
        block_sign_data => $prev . pack("N", $slot) . $digest,
    );
    $stake->calculate_hash;
    return $stake;
}

# Build a slashing tx for a fresh equivocated coin and put it into the mempool.
my $seq = 0;
sub mempool_slashing {
    my $coin = make_coin(pack("H*", sprintf("%02x", ++$seq) x 32), 0, 1000);
    my $tx = QBitcoin::Slashing->new_tx(
        make_stake([$coin], "\x11" x 32, "\xa1" x 32),
        make_stake([$coin], "\x22" x 32, "\xb2" x 32),
    ) or die "can't build slashing tx\n";
    $tx->add_to_cache;
    return ($tx, $coin);
}

# A transaction confirmed at $height and still held in the memory cache.
sub confirmed_spender {
    my ($hash, $height) = @_;
    my $tx = QBitcoin::Transaction->new(
        in => [], out => [], tx_type => TX_TYPE_STANDARD, fee => 0, hash => $hash,
    );
    $tx->block_height($height);
    $tx->block_time($timeslot);
    $tx->add_to_cache;
    return $tx;
}

QBitcoin::Block->max_db_height(10);

# --- the slashed UTXO is still free, or its spend can still be undone -------

my ($free, $free_coin) = mempool_slashing();
QBitcoin::Transaction->cleanup_mempool();
ok(QBitcoin::Transaction->get($free->hash), "slashing tx with an unspent input stays in the mempool");

my ($shallow, $shallow_coin) = mempool_slashing();
$shallow_coin->tx_out = confirmed_spender(pack("H*", "e1" x 32), 11)->hash;
QBitcoin::Transaction->cleanup_mempool();
ok(QBitcoin::Transaction->get($shallow->hash),
    "slashing tx is kept while its input is spent in a block we can still drop");

# --- the spend is out of reach ----------------------------------------------

my ($stored, $stored_coin) = mempool_slashing();
$stored_coin->tx_out = confirmed_spender(pack("H*", "e2" x 32), 10)->hash;
QBitcoin::Transaction->cleanup_mempool();
ok(!QBitcoin::Transaction->get($stored->hash),
    "slashing tx is dropped when its input is spent in an already stored block");

# a spender freed from the transaction cache is below the in-memory levels by definition
my ($freed, $freed_coin) = mempool_slashing();
$freed_coin->tx_out = pack("H*", "e3" x 32);
QBitcoin::Transaction->cleanup_mempool();
ok(!QBitcoin::Transaction->get($freed->hash),
    "slashing tx is dropped when the spending transaction is no longer cached");

ok(QBitcoin::Transaction->get($free->hash), "the includable slashing tx survived all of it");

# --- an unincludable slashing tx must not trigger sibling blocks ------------

ok(QBitcoin::Generate::_have_weight_tx(), "an includable slashing tx is a reason to build a sibling block");
$free_coin->tx_out = pack("H*", "e4" x 32);
ok(!QBitcoin::Generate::_have_weight_tx(), "a slashing tx that can not be included is not");

# --- slashing must not drive a deep reorg -----------------------------------

{
    my $coin = make_coin(pack("H*", "ab" x 32), 0, 1000);
    my $sl = QBitcoin::Slashing->new_tx(
        make_stake([$coin], "\x66" x 32, "\xd1" x 32),
        make_stake([$coin], "\x77" x 32, "\xd2" x 32),
    );
    QBitcoin::Slashing->ban_from_tx($sl);
    my $stake = QBitcoin::Transaction->new(
        in => [], out => [], tx_type => TX_TYPE_STAKE, fee => -1, hash => pack("H*", "99" x 32),
    );
    $stake->block_height(11);
    $stake->block_time($timeslot);
    $stake->add_to_cache;
    $coin->tx_out = $stake->hash;

    is(QBitcoin::Slashing->banned_height_in_best(), 11,
        "an equivocated block above the stored levels is dropped for slashing");
    QBitcoin::Block->max_db_height(11);
    is(QBitcoin::Slashing->banned_height_in_best(), undef,
        "an equivocated block already stored in the database is too deep to drop");
}

done_testing();
