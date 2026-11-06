#! /usr/bin/env perl
use warnings;
use strict;

# A block with a wrong hash at a checkpoint height is rejected. The chain since the previous
# checkpoint is rolled back only when that block extends our best branch below the checkpoint:
# the branch was accepted under partial validation and may come from a malicious peer. A wrong
# block on a side branch, or one received when the checkpoint block is already in the best
# branch, must not roll anything back (otherwise any peer could wipe a synced node).

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(send_block send_tx $connection);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
my $connection_module = Test::MockModule->new('QBitcoin::Connection');
$connection_module->mock('disconnect', sub { 1 });
$config->{regtest} = 1;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

# The checkpoint list is a compile-time constant: checkpoint at height 1, hash "a1"
my %checkpoint = (1 => "a1");
my $receive_module = Test::MockModule->new('QBitcoin::Block::Receive');
$receive_module->mock('max_checkpoint_height', sub { 1 });
$receive_module->mock('checkpoint_hash', sub { $checkpoint{$_[0]} });
$receive_module->mock('prev_checkpoint_height', sub { -1 });
my $validate_module = Test::MockModule->new('QBitcoin::Block::Validate');
$validate_module->mock('checkpoint_hash', sub { $checkpoint{$_[0]} });

blockchain_synced(1);

sub best { QBitcoin::Block->best_block ? QBitcoin::Block->best_block->hash : "none" }

# Below the checkpoint: a wrong checkpoint block extending our best branch rolls it back
my $start_tx = send_tx();
ok(send_block(0, "a0", undef, 50, $start_tx), "block 0 accepted");
is(best(), "a0", "block 0 is the best");

# The checkpoint block itself failing another check (here: its time is ahead of our clock)
# is not a checkpoint mismatch: no rollback
my $early = QBitcoin::Test::Send::make_block(1, "a1", "a0", 60);
$early->time = timeslot(time() + 10 * BLOCK_INTERVAL);
block_hash($early->hash);
$connection->protocol->command("block");
is($connection->protocol->cmd_block($early->serialize), -1, "checkpoint block with a future time rejected");
is(best(), "a0", "best branch unchanged");

ok(!send_block(1, "x1", "a0", 60), "wrong checkpoint block on top of our branch rejected");
is(best(), "none", "best branch below the checkpoint rolled back");

# The correct chain through the checkpoint
ok(send_block(0, "a0", undef, 50, $start_tx), "block 0 accepted again");
ok(send_block(1, "a1", "a0", 60), "checkpoint block accepted");
ok(send_block(2, "a2", "a1", 70), "block above the checkpoint accepted");
is(best(), "a2", "block above the checkpoint is the best");

# The checkpoint block is in the best branch: a wrong sibling does not roll anything back
ok(!send_block(1, "y1", "a0", 65), "wrong checkpoint block with the same parent rejected");
is(best(), "a2", "best branch unchanged");
is(QBitcoin::Block->best_block->height, 2, "best height unchanged");

# A wrong checkpoint block on a side branch does not roll anything back either
ok(send_block(0, "c0", undef, 40), "alternative block 0 processed");
is(best(), "a2", "alternative block 0 is not the best");
ok(!send_block(1, "z1", "c0", 45), "wrong checkpoint block on the side branch rejected");
is(best(), "a2", "best branch unchanged");

done_testing();
