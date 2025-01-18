#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Const;
BEGIN { no warnings 'redefine'; *QBitcoin::Const::MAX_EMPTY_TX_IN_BLOCK = sub () { 100 } };
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::ProtocolState qw(blockchain_synced);

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
$config->{regtest} = 1;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { $_[0]->{min_tx_time} = $_[0]->{min_tx_block_height} = -1; return 0; });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => '127.0.0.1');
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
blockchain_synced(1);

my $prev_tx;

sub send_tx {
    my ($fee, $prev) = @_;
    my $tx = make_tx(@_>1 ? $prev : $prev_tx, $fee // 0);
    $connection->protocol->command("tx");
    $connection->protocol->cmd_tx($tx->serialize . "\x00"x16);
    $prev_tx = $tx;
    return $tx;
}

sub send_block {
    my ($height, $hash, $prev_hash, $weight, $tx) = @_;
    my @tx = ref($tx) eq "ARRAY" ? @$tx : ($tx);
    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + ($height - STAKE_MATURITY) * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => \@tx,
        weight       => $weight,
    );
    $block->add_tx($_) foreach @tx;
    $block->merkle_root = $block->calculate_merkle_root();
    my $block_data = $block->serialize;
    block_hash($block->hash);
    $connection->protocol->command("block");
    $connection->protocol->cmd_block($block_data);
}

# height, hash, prev_hash, weight, $tx
my $coinbase1 = send_tx(0, undef);
my $coinbase2 = send_tx(0, undef);
send_block(0, "a0", undef, 50, [ $coinbase1, $coinbase2 ]);
my $stake = send_tx(-1, $coinbase1);
my $spend_stake = send_tx(0, $stake);
my $tx1 = send_tx(1, $coinbase2);
send_block(1, "a1", "a0", 100, [ $stake, $tx1 ]);
my $h = int(STAKE_MATURITY / BLOCK_INTERVAL / FORCE_BLOCKS) + 1;
for (my $height = 2; $height < $h; $height++) {
    send_block($height, "a$height", "a" . ($height-1), $height*100, send_tx());
}
send_block($h, "a$h", "a" . ($h-1), $h*100, $spend_stake);
is(QBitcoin::Block->blockchain_height, $h-1, "spend stake disabled");
send_block($h, "a$h", "a" . ($h-1), $h*100, send_tx());
send_block($h+1, "a" . ($h+1), "a$h", ($h+1)*100, $spend_stake);
is(QBitcoin::Block->blockchain_height, $h+1, "spend stake successful");
my $coinbase3 = send_tx(0, undef);
my $tx2 = send_tx(1);
my $stake_spend_stake = send_tx(-1, $stake);
send_block($h, "b$h", "a" . ($h-1), ($h+2)*100, [ $stake_spend_stake, $coinbase3, $tx2 ]);
is(QBitcoin::Block->blockchain_height, $h, "stake spend stake successful");

done_testing();
