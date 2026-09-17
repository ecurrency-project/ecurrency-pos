#! /usr/bin/env perl
use warnings;
use strict;

# The lock script of the btc upgrade transaction may have been changed by a hardfork.
# Below the last checkpoint (partial validation, skip_scripts) a coinbase whose btc output
# does not match the current lock script is still deserialized, with the scripthash of the
# transaction output (as the full validation would require), and passes the partial
# validation. Under the full validation such a coinbase is not deserialized at all.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::ProtocolState qw(skip_scripts);
use QBitcoin::Coinbase;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use Bitcoin::Serialized;
use Bitcoin::Transaction;
use Bitcoin::Block;
use QBitcoin::Block;

$config->{regtest} = 1;

# Btc transaction paying to an ordinary P2PKH output, not to the current lock script
my $value = 100000;
my $old_lock_script = OP_DUP . OP_HASH160 . pack("C", 20) . hash160("old lock") . OP_EQUALVERIFY . OP_CHECKSIG;
isnt($old_lock_script, QBT_BURN_SCRIPT, "output script differs from the current lock script");
my $btc_tx_data = pack("VC", 1, 1); # version, txin_count
$btc_tx_data .= "\x00" x 36 . "\x00" . "\x00" x 4; # prev output, script (var_str), sequence
$btc_tx_data .= pack("C", 1); # txout_count
$btc_tx_data .= pack("Q<", $value) . pack("C", length($old_lock_script)) . $old_lock_script;
$btc_tx_data .= pack("V", 0); # lock_time
my $btc_tx = Bitcoin::Transaction->deserialize(Bitcoin::Serialized->new($btc_tx_data));

my $scripthash = hash160("qbt owner");
my $up = QBitcoin::Coinbase->new({
    btc_block_height => 1,
    btc_block_hash   => "\xab" x 32,
    btc_tx_num       => 0,
    btc_out_num      => 0,
    btc_tx_hash      => $btc_tx->hash,
    btc_tx_data      => $btc_tx->data,
    merkle_path      => "\xcd" x 32,
    value_btc        => $value,
    value            => $value,
    upgrade_level    => 0,
    scripthash       => $scripthash,
});
my $out = QBitcoin::TXO->new_txo({
    value      => int($value * (1 - UPGRADE_FEE)),
    scripthash => $scripthash,
    data       => "",
});
my $tx = QBitcoin::Transaction->new({
    in            => [],
    out           => [ $out ],
    up            => $up,
    fee           => 0,
    tx_type       => TX_TYPE_COINBASE,
    upgrade_level => 0,
});
$tx->calculate_hash;
my $tx_data = $tx->serialize;
undef $tx;
undef $out;
undef $up;

skip_scripts(0);
ok(!QBitcoin::Transaction->deserialize(Bitcoin::Serialized->new($tx_data)),
    "coinbase with a non-matching lock script is not deserialized under full validation");

skip_scripts(1);
my $lenient = QBitcoin::Transaction->deserialize(Bitcoin::Serialized->new($tx_data));
ok($lenient, "coinbase with a non-matching lock script is deserialized under partial validation");
is($lenient->up->scripthash, $scripthash, "coinbase scripthash is taken from the transaction output");
is($lenient->validate, 0, "coinbase passes the partial validation");

# The coinbase record must not be stored on the partial receive: after the transaction is
# dropped when the checkpoint is reached, Coinbase::get_new would build our own (invalid)
# coinbase transaction from it
# the btc block of the coinbase, so that the record can be stored at all
Bitcoin::Block->new(
    version     => 1,
    height      => 1,
    hash        => "\xab" x 32,
    prev_hash   => ZERO_HASH,
    merkle_root => "\x11" x 32,
    time        => time(),
    bits        => 1234,
    chainwork   => 1,
    nonce       => 0,
    scanned     => 1,
)->create;
sub coinbase_stored { scalar(() = QBitcoin::Coinbase->fetch(btc_block_height => 1, btc_tx_num => 0, btc_out_num => 0)) }
ok($lenient->load_txo, "transaction outputs loaded");
is($lenient->receive, 0, "coinbase transaction accepted under the partial validation");
is(coinbase_stored(), 0, "coinbase record is not stored");

# A coinbase confirmed below the checkpoint is stored with its transaction. If the blocks
# are then deleted (checkpoint failure) the record must go with the transaction, otherwise
# it would stay as an unpublished upgrade (tx_out NULL) our own coinbase transaction is
# built from, although its lock script was never checked.
my $block_module = Test::MockModule->new("QBitcoin::Block");
$block_module->mock("max_checkpoint_height", sub { 1 });
QBitcoin::Block->QBitcoin::ORM::create({
    height => 1, time => GENESIS_TIME + BLOCK_INTERVAL * FORCE_BLOCKS, hash => "\x01" x 32,
    size => 0, weight => 1, upgraded => 0, reward_fund => 0, min_fee => 0,
    prev_hash => ZERO_HASH, merkle_root => ZERO_HASH,
});
$lenient->block_height = 1;
$lenient->block_pos = 0;
$lenient->store;
is(coinbase_stored(), 1, "coinbase record stored with the confirmed transaction");
QBitcoin::Block->delete_since_height(1);
is(coinbase_stored(), 0, "coinbase record deleted with the blocks below the checkpoint");

done_testing();
