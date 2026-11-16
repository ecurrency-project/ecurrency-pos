#! /usr/bin/env perl
use warnings;
use strict;

# The scripts of a stake transaction are executed for each block it is included in, so the
# node takes a stake transaction only when it is delivered for a pending block which waits
# for it, and one delivery is for one block. Each check of the scripts is then paid by the
# delivery of the transaction: small blocks can not have a large stake transaction checked
# again and again for free.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(make_block send_block send_tx send_raw_tx $connection);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Protocol;
use QBitcoin::Connection;
use QBitcoin::Peer;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::ProtocolState qw(blockchain_synced);

#$config->{debug} = 1;
$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $stake_checks = 0; # how many times the scripts of a stake transaction were executed
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });
$transaction_module->mock('check_input_script', sub {
    $stake_checks++ if $_[0]->is_stake;
    return $transaction_module->original('check_input_script')->(@_);
});

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

my $peer2 = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => IPV6_V4_PREFIX . pack("C4", 127, 0, 0, 2));
my $connection2 = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer2);

# The messages are sent one by one here: send_block() delivers the stake transaction itself
sub block_msg {
    my ($from, @block) = @_;
    my $block = make_block(@block);
    block_hash($block->hash);
    $from->protocol->command("block");
    return $from->protocol->cmd_block($block->serialize);
}

sub tx_msg {
    my ($from, $tx) = @_;
    $from->protocol->command("tx");
    return $from->protocol->cmd_tx($tx->serialize . "\x00" x 16);
}

sub received { scalar grep { QBitcoin::Block->block_pool($_) } @_ }

blockchain_synced(1);

# height, hash, prev_hash, weight, $tx
my $coin  = send_tx(0, undef);
my $coin3 = send_tx(0, undef);
my $funds = send_tx(0, undef);
send_block(0, "a0", undef, 100, $coin, $coin3, $funds);
my $fee_tx = send_tx(1, $funds); # the reward of the blocks with the stake transaction
send_block(1, "x1", "a0", 1000, send_tx(0, undef));
# The stake transaction has no signature to check, so it fits any block;
# the blocks below are lighter than the best one and differ only by the declared weight
my $stake = make_tx($coin, -1);
my @txs = ($stake, $fee_tx);

tx_msg($connection, $stake);
ok(!QBitcoin::Transaction->get($stake->hash), "a stake transaction no block waits for is not taken");

block_msg($connection, 1, "b1", "a0", 110, @txs);
block_msg($connection, 1, "b2", "a0", 120, @txs);
tx_msg($connection, $stake);
is(received("b1", "b2"), 1, "one delivery of the stake transaction is for one of the two blocks waiting for it");
is($stake_checks, 1, "its scripts are checked once");
tx_msg($connection, $stake);
is(received("b1", "b2"), 2, "the other block is received with the second delivery");
is($stake_checks, 2, "the scripts are checked for it");
tx_msg($connection, $stake);
is($stake_checks, 2, "one more delivery checks nothing: no block waits for it");

block_msg($connection, 1, "b3", "a0", 130, @txs);
is(received("b3"), 0, "a block with the known stake transaction waits for its own delivery");
is($stake_checks, 2, "nothing is checked before the delivery");
tx_msg($connection, $stake);
is(received("b3"), 1, "the block is received with the delivery");
is($stake_checks, 3, "the scripts are checked for it");

# Two peers: the block of the second peer is the older one
block_msg($connection2, 1, "c1", "a0", 140, @txs);
block_msg($connection,  1, "c2", "a0", 150, @txs);
tx_msg($connection, $stake);
ok(received("c2") && !received("c1"), "the stake transaction delivered by a peer is for the block of this peer");
tx_msg($connection, $stake);
is(received("c1"), 0, "a peer can not deliver it for the block of another peer");
tx_msg($connection2, $stake);
is(received("c1"), 1, "the block is received when its peer delivers the stake transaction");
is($stake_checks, 5, "the scripts are checked once for each of the two blocks");

# The transactions of the pending block of the first peer are requested from the second one
block_msg($connection,  1, "d1", "a0", 160, @txs);
block_msg($connection2, 1, "d1", "a0", 160, @txs);
tx_msg($connection2, $stake);
is(received("d1"), 1, "the stake transaction is taken from the peer it was requested from");

# The same when the block waited for its ancestor and the ancestor came from the second peer
my $coinbase = send_tx(0, undef);
block_msg($connection,  2, "g2", "g1", 300, @txs);
block_msg($connection2, 1, "g1", "a0", 200, $coinbase);
tx_msg($connection2, $stake);
is(received("g2"), 1, "...and from the peer which sent the ancestor of the block");

# The deliveries are counted while the stake transaction waits for its input
my $coin2 = make_tx(undef, 0);
my $stake2 = make_tx($coin2, -1);
block_msg($connection,  1, "e1", "a0", 170, $stake2, $fee_tx);
block_msg($connection2, 1, "e2", "a0", 180, $stake2, $fee_tx);
tx_msg($connection, $stake2);
tx_msg($connection2, $stake2);
is(received("e1", "e2"), 0, "the blocks wait for the stake transaction which waits for its input");
send_raw_tx($coin2);
is(received("e1", "e2"), 2, "both blocks the stake transaction was delivered for are received when its input comes");

# The delivered stake transaction is lost while it waits for its input: the block takes it again
my $coin4 = make_tx(undef, 0);
my $stake4 = make_tx($coin4, -1);
block_msg($connection, 1, "f1", "a0", 190, $stake4, $fee_tx);
tx_msg($connection, $stake4);
QBitcoin::Transaction->drop_all_pending();
ok(!QBitcoin::Transaction->has_pending($stake4->hash), "the stake transaction waiting for its input is dropped");
tx_msg($connection, $stake4);
send_raw_tx($coin4);
is(received("f1"), 1, "the block is received with the stake transaction delivered again");

# A stake transaction stored in the database is delivered for a block as well
my $stake3 = make_tx($coin3, -1);
send_block(2, "y2", "x1", 1100, $stake3, $fee_tx);
send_block($_, "y$_", "y" . ($_ - 1), 1000 + $_ * 100, send_tx(0, undef)) foreach 3 .. 10;
QBitcoin::Block->store_blocks();
QBitcoin::Block->cleanup_old_blocks();
cmp_ok(QBitcoin::Block->min_incore_height, '>', 2, "the block with the stake transaction is stored");
ok(!QBitcoin::Transaction->get($stake3->hash), "its stake transaction is not in memory");
$stake_checks = 0;
block_msg($connection, 2, "z2", "x1", 1050, $stake3, $fee_tx);
is(received("z2"), 0, "a block with the stored stake transaction waits for the delivery");
is($stake_checks, 0, "nothing is checked before the delivery");
tx_msg($connection, $stake3);
is(received("z2"), 1, "the block is received with the delivery");
is($stake_checks, 1, "the scripts are checked for it");

done_testing();
