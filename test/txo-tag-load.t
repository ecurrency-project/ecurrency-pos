#! /usr/bin/env perl
use warnings;
use strict;

# Tagged TXO data must survive the DB round-trip of get_address_utxo:
# load_address_utxo caches wallet UTXOs on startup, and a stripped data field
# poisons the TXO cache — the node stakes foreign tagged genesis parts as its
# own, and any stored transaction sharing such a cached output fails the
# "Incorrect hash for loaded transaction" check on load (getrawtransaction).

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::Send qw(send_block send_raw_tx send_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Block;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Generate;
use QBitcoin::Address qw(address_by_hash);
use QBitcoin::Crypto qw(hash160);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Utils qw(get_address_utxo);

$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

my $tag        = "t2";
my $script     = OP_1;
my $scripthash = hash160($script);

my $out = QBitcoin::TXO->new_txo(
    value      => 1000,
    scripthash => $scripthash,
    num        => 0,
    data       => TXO_DATA_TAG . $tag,
);
my $tx = QBitcoin::Transaction->new(
    out           => [ $out ],
    in            => [],
    fee           => 0,
    tx_type       => TX_TYPE_COINBASE,
    coins_created => 1000,
);
$tx->calculate_hash;
$out->tx_in = $tx->hash;
my $tx_hash = $tx->hash;
send_raw_tx($tx)
    or die "Can't send tagged coinbase tx\n";

send_block(0, "a0", undef, 1, $tx);
foreach my $height (1 .. 10) {
    send_block($height, "a$height", "a" . ($height-1), 50 + $height*2, send_tx(0, undef));
}

QBitcoin::Block->store_blocks();
QBitcoin::Block->cleanup_old_blocks();
undef $tx;
undef $out;

pass("Blocks stored successfully");

# get_address_utxo must return the raw data (plus the display tag) for a stored txo
my ($chain_utxo, $mempool_utxo) = get_address_utxo(address_by_hash($scripthash));
my $utxo = $chain_utxo->{$tx_hash} && $chain_utxo->{$tx_hash}->[0];
ok($utxo, "tagged utxo found in stored chain");
is($utxo && $utxo->{data}, TXO_DATA_TAG . $tag, "raw data preserved for stored tagged utxo");
# The display tag is derived from the raw data by the RPC/REST output layer;
# get_address_utxo returns internal raw structures only
ok($utxo && !exists $utxo->{tag}, "no display tag in get_address_utxo result");

# Wallet startup load must not poison the TXO cache: the stored transaction must
# still load from the database with a matching hash afterwards
my $generate_module = Test::MockModule->new('QBitcoin::Generate');
$generate_module->mock('load_reclaim_utxo', sub {});
my $my_address = FakeAddress->new(
    address    => address_by_hash($scripthash),
    scripthash => $scripthash,
);
QBitcoin::Generate->load_address_utxo($my_address);

my $cached = QBitcoin::TXO->get({ tx_out => $tx_hash, num => 0 });
ok($cached, "wallet utxo cached after load_address_utxo");
is($cached && $cached->data, TXO_DATA_TAG . $tag, "cached wallet utxo keeps raw tag data");

my $loaded = eval { QBitcoin::Transaction->get_by_hash($tx_hash) };
ok($loaded, "stored transaction loads after wallet utxo load") or diag($@);
is($loaded && $loaded->out->[0]->data, TXO_DATA_TAG . $tag, "loaded transaction output keeps tag data");

done_testing();

package FakeAddress;

sub new {
    my $class = shift;
    return bless { @_ }, $class;
}

sub address    { $_[0]->{address} }
sub scripthash { $_[0]->{scripthash} }
