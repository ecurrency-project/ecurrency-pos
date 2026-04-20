#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::Send qw(make_block send_block send_tx $connection $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Block;
use QBitcoin::Revalidate qw(revalidate);

#$config->{debug} = 1;
$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

my @blocks; # save for resend

send_block(0, "a0", undef, 1, send_tx());
my $stake = send_tx(-1);

push @blocks, send_block(1, "a1", "a0", 52, $stake, send_tx(1, undef));
my $h = int(STAKE_MATURITY / BLOCK_INTERVAL / FORCE_BLOCKS) + 1;
foreach my $height (2 .. $h) {
    push @blocks, send_block($height, "a$height", "a" . ($height-1), 50 + $height*2, send_tx());
}
push @blocks, send_block($h+1, "a" . ($h+1), "a$h", 52 + $h*2, send_tx(0, $stake));
foreach my $height ($h+2 .. $h+10) {
    push @blocks, send_block($height, "a$height", "a" . ($height-1), 50 + $height*2, send_tx());
}

QBitcoin::Block->store_blocks();
QBitcoin::Block->cleanup_old_blocks();

pass("Blocks stored successfully");

$block_module->mock('validate', sub {
    my ($self) = @_;
    return $self->height == 0 ? "" : "Incorrect block";
});

revalidate();

$block_module->unmock('validate');

$connection->protocol->command("block");

foreach my $block (@blocks) {
    my $block_data = $block->serialize;
    block_hash($block->hash);
    $connection->protocol->cmd_block($block_data);
}

$connection->protocol->command("tx");
$connection->protocol->cmd_tx($stake->serialize . "\x00"x16);

is(QBitcoin::Block->blockchain_height(), scalar(@blocks), "Blockchain height matches number of blocks sent");

done_testing();
