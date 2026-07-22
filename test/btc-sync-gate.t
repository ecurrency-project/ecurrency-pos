#! /usr/bin/env perl
use warnings;
use strict;

# During initial sync a coinbase (upgrade) transaction may arrive before the BTC
# blockchain is synced, so it cannot be validated. Such transaction must be ignored
# without aborting the connection and without penalizing the peer, and no QBT
# blocks or transactions must be requested until the BTC blockchain is synced.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::ProtocolState qw(blockchain_synced btc_synced);
use QBitcoin::Coinbase;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Block;
use QBitcoin::Connection;
use QBitcoin::Peer;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use Bitcoin::Serialized;
use Bitcoin::Transaction;
use Bitcoin::Block;

$config->{regtest} = 1;

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => IPV6_V4_PREFIX . pack("C4", 127, 0, 0, 1));
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
my $protocol = $connection->protocol;

# Coinbase referring to a BTC block we do not have; the btc_block table is empty,
# so the coinbase cannot be validated: BTC blockchain is not synced
my $value = 100000;
my $open_script = hash160("\x10\x11");
my $btc_tx_data = pack("VC", 1, 1); # version, txin_count
$btc_tx_data .= "\x00" x 36 . "\x00" . "\x00" x 4; # prev output, script (var_str), sequence
$btc_tx_data .= pack("C", 2); # txout_count
my $upgrade_script = QBT_BURN_SCRIPT;
$btc_tx_data .= pack("Q<", $value) . pack("C", length($upgrade_script)) . $upgrade_script;
$btc_tx_data .= pack("Q<", 0) . pack("C", length($open_script)+2) . OP_RETURN . pack("C", length($open_script)) . $open_script;
$btc_tx_data .= pack("V", 0); # lock_time

my $data_obj = Bitcoin::Serialized->new($btc_tx_data);
my $btc_tx = Bitcoin::Transaction->deserialize($data_obj);

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
    scripthash       => QBitcoin::Coinbase->get_scripthash($btc_tx, 0),
});
my $out = QBitcoin::TXO->new_txo({
    value      => int($value * (1 - UPGRADE_FEE)),
    scripthash => $open_script,
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
my $tx_hash = $tx->hash;
my $tx_data = $tx->serialize;

btc_synced(0);
blockchain_synced(0);

is($up->validate(), -1, "coinbase validation fails when BTC blockchain is not synced");

# Free the local objects so cmd_tx deserializes and processes its own copies
undef $tx;
undef $out;
undef $up;

my $rep_before = $peer->reputation;

# A transaction arriving while btc_synced is already unset is ignored before validation
$connection->sendbuf = "";
$protocol->command("tx");
is($protocol->cmd_tx($tx_data . "\x00" x 16), 0, "cmd_tx ignores tx while BTC is not synced");
ok(index($connection->sendbuf, "reject") == -1, "no reject sent");
ok(!QBitcoin::Transaction->check_by_hash($tx_hash), "ignored transaction is not stored");

is($peer->reputation, $rep_before, "peer reputation is not decreased");

# A coinbase arriving while btc_synced is stale (set, but the BTC tip is not fresh)
# is rejected as invalid: an unknown btc block is indistinguishable from a fake one.
# Validation resets btc_synced, so subsequent transactions are ignored without penalty.
btc_synced(1);
$connection->sendbuf = "";
is($protocol->cmd_tx($tx_data . "\x00" x 16), -1, "cmd_tx rejects unvalidatable coinbase when btc_synced is stale");
ok(index($connection->sendbuf, "reject") != -1, "reject sent");
ok(!btc_synced(), "stale btc_synced is reset by coinbase validation");
ok(!QBitcoin::Transaction->check_by_hash($tx_hash), "rejected transaction is not stored");

# No QBT block requests until the BTC blockchain is synced
my $ihave = pack("VQ<a32", time() - 3600, 100, "\xaa" x 32);
$connection->sendbuf = "";
$protocol->command("ihave");
is($protocol->cmd_ihave($ihave), 0, "cmd_ihave ok while BTC is not synced");
is($connection->sendbuf, "", "no block requests while BTC is not synced");
btc_synced(1);
is($protocol->cmd_ihave($ihave), 0, "cmd_ihave ok after BTC is synced");
ok(index($connection->sendbuf, "getblks") != -1, "blocks requested after BTC is synced");
$protocol->syncing(0);

# No QBT transaction requests until the BTC blockchain is synced
blockchain_synced(1);
btc_synced(0);
$connection->sendbuf = "";
$protocol->command("ihavetx");
is($protocol->cmd_ihavetx("\xbb" x 32), 0, "cmd_ihavetx ok while BTC is not synced");
is($connection->sendbuf, "", "no tx request while BTC is not synced");
btc_synced(1);
is($protocol->cmd_ihavetx("\xbb" x 32), 0, "cmd_ihavetx ok after BTC is synced");
ok(index($connection->sendbuf, "sendtx") != -1, "tx requested after BTC is synced");

# An incoming QBT block is ignored until the BTC blockchain is synced
my $block_data = pack("VQ<", time() - 3600, 100) . "\xee" x 32 . ZERO_HASH . "\x00" x 16 . pack("v", 0);
my $block_hash = QBitcoin::Block->deserialize(Bitcoin::Serialized->new($block_data))->hash;
blockchain_synced(0);
btc_synced(0);
$connection->sendbuf = "";
$protocol->command("block");
is($protocol->cmd_block($block_data), 0, "cmd_block ok while BTC is not synced");
is($connection->sendbuf, "", "block ignored while BTC is not synced");
ok(!QBitcoin::Block->block_pool($block_hash) && !QBitcoin::Block->is_pending($block_hash), "ignored block is not stored");
btc_synced(1);
is($protocol->cmd_block($block_data), 0, "cmd_block ok after BTC is synced");
ok(index($connection->sendbuf, "getblks") != -1, "block processed after BTC is synced");

# With a fresh BTC tip, a coinbase referring to an unknown btc block is simply invalid
# and must not reset btc_synced
my $fresh_block = Bitcoin::Block->new(
    version     => 1,
    height      => 1,
    prev_hash   => ZERO_HASH,
    merkle_root => "\x11" x 32,
    time        => time(),
    bits        => 1234,
    chainwork   => 1,
    nonce       => 0,
    scanned     => 1,
);
$fresh_block->hash = $fresh_block->calculate_hash;
$fresh_block->create;
my $up2 = QBitcoin::Coinbase->new({
    btc_block_height => 2,
    btc_block_hash   => "\xab" x 32,
    btc_tx_num       => 0,
    btc_out_num      => 0,
    btc_tx_hash      => $btc_tx->hash,
    btc_tx_data      => $btc_tx->data,
    merkle_path      => "\xcd" x 32,
    value_btc        => $value,
    value            => $value,
    upgrade_level    => 0,
    scripthash       => QBitcoin::Coinbase->get_scripthash($btc_tx, 0),
});
btc_synced(1);
is($up2->validate(), -1, "coinbase with unknown btc block is invalid when the BTC tip is fresh");
ok(btc_synced(), "btc_synced is not reset when the BTC tip is fresh");

done_testing();
