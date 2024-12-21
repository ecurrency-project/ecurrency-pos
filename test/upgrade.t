#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::Coinbase;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Block;
use Bitcoin::Block;
use Bitcoin::Serialized;
use Bitcoin::Transaction;

#$config->{debug} = 1;

my $value = 100000; # random value
my $open_script = hash160("\x10\x11"); # random string

my $btc_tx_data = pack("VC", 1, 1); # version, txin_count
$btc_tx_data .= "\x00" x 36 . "\x00" . "\x00" x 4; # prev output, script (var_str), sequence
$btc_tx_data .= pack("C", 1); # txout_count
$btc_tx_data .= pack("Q<", $value) . pack("C", QBT_SCRIPT_START_LEN + length($open_script)) . QBT_SCRIPT_START . $open_script;
$btc_tx_data .= pack("V", 0); # lock_time

my $data_obj = Bitcoin::Serialized->new($btc_tx_data);
my $btc_tx = Bitcoin::Transaction->deserialize($data_obj);
my $prev_hash = ZERO_HASH;
my $time = time();
my @btc_block;
for (my $height = 1; $height <= 7; $height++) {
    my $blk = Bitcoin::Block->new(
        version      => 1,
        height       => $height,
        prev_hash    => $prev_hash,
        transactions => $height == 1 ? [ $btc_tx ] : [],
        time         => $time - 6*3600 + $height*60,
        bits         => 1234,
        chainwork    => 11112222,
        nonce        => 0,
        scanned      => 1,
    );
    $blk->merkle_root = $blk->calculate_merkle_root;
    $prev_hash = $blk->hash = $blk->calculate_hash;
    $blk->create;
    $btc_block[$height] = $blk;
}

my $btc_tx_num = 0;
my $btc_out_num = 0;
my $up = QBitcoin::Coinbase->new({
    btc_block_height => $btc_block[1]->height,
    btc_tx_num       => $btc_tx_num,
    btc_out_num      => $btc_out_num,
    btc_tx_hash      => $btc_tx->hash,
    btc_tx_data      => $btc_tx->data,
    merkle_path      => $btc_block[1]->merkle_path($btc_tx_num),
    value            => $value,
    scripthash       => substr($btc_tx->out->[$btc_out_num]->{open_script}, QBT_SCRIPT_START_LEN),
});

my $out = QBitcoin::TXO->new_txo({
    value      => int($value * (1 - UPGRADE_FEE)),
    scripthash => $open_script,
});

sub tx {
    my $tx = QBitcoin::Transaction->new({
        in      => [],
        out     => [ $out ],
        up      => $up,
        fee     => 0,
        tx_type => TX_TYPE_COINBASE,
    });
    $tx->calculate_hash;
    return $tx;
}

my $tx = tx();
$out->tx_out = $tx->hash;
$out->num = 0;

{
    local $out->{value} = $value + 1;
    isnt($tx->validate(), 0, "Too large value");
    $out->{value} = $value - 1;
    isnt($tx->validate(), 0, "Too small value");
}
{
    local $out->{scripthash} = hash160("\x10\x11\x12");
    isnt($tx->validate(), 0, "Incorrect scripthash");
}
{
    my $extra_out = QBitcoin::TXO->new_txo({ value => 10, scripthash => hash160("\x01\x02"), num => 1 });
    local $tx->{out} = [ $out, $extra_out ];
    local $tx->{hash};
    $tx->calculate_hash;
    local $out->{tx_out} = $extra_out->tx_out;
    isnt($tx->validate(), 0, "Extra output");
}
{
    my $extra_in = QBitcoin::TXO->new_txo({ value => 10, redeem_script => "\x01\x02", scripthash => hash160("\x01\x02"), tx_out => "\xaa" x 32, num => 1 });
    local $tx->{in} = [ { txo => $extra_in, siglist => [] } ];
    isnt($tx->validate(), 0, "Extra input");
}
{
    local $up->{merkle_path} = $up->{merkle_path};
    substr($up->{merkle_path}, 0, 4, "\x98\x76\x54\x32");
    isnt($tx->validate(), 0, "Extra input");
}
{
    local $up->{btc_block_height} = 14;
    delete local $up->{btc_block_hash};
    isnt($tx->validate(), 0, "Incorrect btc block");
}
SKIP: {
    skip "tx->data not implemented", 1;
    local $tx->{data} = "Coinbase data";
    isnt($tx->validate(), 0, "Coinbase with data");
}

is($tx->validate(), 0, "Correct coinbase");

# valid_for_block() saves min_tx_time in the transaction object, so rebuild it
$tx = tx();
my $block = QBitcoin::Block->new( time => $btc_block[7]->time + 2*3600 - 15, height => 1 );
isnt($tx->valid_for_block($block), 0, "Early block");
$tx = tx();
$block->time = $btc_block[7]->time + 2*3600 + 15;
is($tx->valid_for_block($block), 0, "Valid for block");

$tx = tx();
$btc_block[7]->delete;
delete $up->{btc_confirm_time};
isnt($tx->valid_for_block($block), 0, "Not enough confirmations");

done_testing();
