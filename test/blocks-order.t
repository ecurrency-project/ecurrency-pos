#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(make_block send_block send_tx $connection $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
$config->{regtest} = 1;

my @block_hash;

sub block_hashes {
    push @block_hash, @_;
}

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('calculate_hash', sub { shift @block_hash });
$block_module->mock('static_reward', sub { 0 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

sub send_blocks {
    my @blocks = @_;
    block_hashes($_->hash) foreach @blocks;
    $connection->protocol->command("blocks");
    return $connection->protocol->cmd_blocks(pack("C", scalar(@blocks)) . join("", map { $_->serialize } @blocks));
}

blockchain_synced(1);

send_block(0, "a0", undef, 10, send_tx());
send_block(1, "a1", "a0", 20, send_tx());
send_block(2, "a2", "a1", 30, send_tx());
send_block(3, "a3", "a2", 40, send_tx());
send_block(4, "a4", "a3", 50, send_tx());

send_block(4, "c4", "b3", 60, send_tx(0, undef));

my $block2 = make_block(2, "b2", "a1", 30, send_tx(0, undef));
my $block3 = make_block(3, "b3", "b2", 40, send_tx());
my $block4 = make_block(4, "b4", "b3", 70, send_tx());

my $rc = send_blocks($block2, $block3, $block4);
is($rc, 0, "Blocks sent successfully");

my $block = QBitcoin::Block->best_block();
is($block->hash, "b4", "Best block is b4");

done_testing();
