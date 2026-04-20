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
use QBitcoin::Test::Send qw(send_tx send_block);
use QBitcoin::Config;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::ProtocolState qw(blockchain_synced);

#$config->{debug} = 1;
$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { $_[0]->{min_tx_time} = $_[0]->{min_tx_block_height} = -1; return 0; });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

blockchain_synced(1);

# height, hash, prev_hash, weight, $tx
my $coinbase1 = send_tx(0, undef);
my $coinbase2 = send_tx(0, undef);
send_block(0, "a0", undef, 50, $coinbase1, $coinbase2);
my $stake = send_tx(-1, $coinbase1);
my $spend_stake = send_tx(0, $stake);
my $tx1 = send_tx(1, $coinbase2);
send_block(1, "a1", "a0", 100, $stake, $tx1);
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
send_block($h, "b$h", "a" . ($h-1), ($h+2)*100, $stake_spend_stake, $coinbase3, $tx2);
is(QBitcoin::Block->blockchain_height, $h, "stake spend stake successful");

done_testing();
