#! /usr/bin/env perl
use warnings;
use strict;

# While the best branch is below the last checkpoint the validation is partial (no script
# checks): the chain there is settled by the checkpoint hash and the rules may have changed
# since. When the checkpoint block is accepted, everything received so far but not yet in the
# best branch (pending blocks, mempool and pending transactions) is dropped: it was validated
# only partially and may be invalid by the current rules. From then on the validation is full,
# and a block below the checkpoint can not switch it back.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(send_block send_tx send_raw_tx $connection);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ProtocolState qw(blockchain_synced skip_scripts);
use QBitcoin::Block;
use QBitcoin::Transaction;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
$config->{regtest} = 1;

my %bad; # transactions failing the script check
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });
$transaction_module->mock('check_input_script', sub { $bad{$_[0]->hash} ? -1 : $transaction_module->original('check_input_script')->(@_) });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

# The checkpoint list is a compile-time constant; the receive path reads only its last height
my $receive_module = Test::MockModule->new('QBitcoin::Block::Receive');
$receive_module->mock('max_checkpoint_height', sub { 1 });

blockchain_synced(1);

sub cached { QBitcoin::Transaction->get($_[0]->hash) ? 1 : 0 }

my $start_tx = send_tx();
ok(send_block(0, "a0", undef, 50, $start_tx), "block 0 (below the checkpoint) accepted");
ok(skip_scripts(), "partial validation while the best branch is below the checkpoint");

my $good = send_tx(0, $start_tx);
ok($good && cached($good), "valid transaction accepted");
my $bad = make_tx($good, 0);
$bad{$bad->hash} = 1;
ok(send_raw_tx($bad), "transaction with a bad script accepted under partial validation");
my $unknown = make_tx($bad, 0); # never sent
my $pending_tx = make_tx($unknown, 0);
ok(send_raw_tx($pending_tx), "transaction with unknown input received");
ok(QBitcoin::Transaction->has_pending($pending_tx->hash), "transaction is pending");
# A block above the checkpoint pending for its (unknown) ancestor
$connection->protocol->command("block");
my $above = QBitcoin::Test::Send::make_block(2, "a2", "a1", 70, $bad);
block_hash($above->hash);
is($connection->protocol->cmd_block($above->serialize), 0, "block above the checkpoint with unknown ancestor received");
ok(QBitcoin::Block->is_pending("a2"), "block is pending");

# The checkpoint block: accepted under partial validation, switches to the full one
ok(send_block(1, "a1", "a0", 60), "checkpoint block accepted");
ok(!skip_scripts(), "full validation once the checkpoint is reached");
ok(!QBitcoin::Block->is_pending("a2"), "pending block dropped");
ok(!QBitcoin::Transaction->has_pending($pending_tx->hash), "pending transaction dropped");
is(cached($bad),  0, "mempool transaction with a bad script dropped");
is(cached($good), 0, "valid mempool transaction dropped too, to be received again");
is(QBitcoin::Block->best_block->hash, "a1", "checkpoint block is the best");

# Full validation from now on
my $good2 = send_tx(0, $start_tx);
ok($good2 && cached($good2), "valid transaction accepted again");
my $bad2 = make_tx($good2, 0);
$bad{$bad2->hash} = 1;
ok(!send_raw_tx($bad2), "transaction with a bad script rejected");
is(cached($bad2), 0, "rejected transaction is not in the mempool");
ok(send_block(2, "b2", "a1", 70, $good2), "block above the checkpoint accepted");
is(QBitcoin::Block->best_block->hash, "b2", "block above the checkpoint is the best");

# A block below the checkpoint arriving later does not switch the partial validation back
ok(send_block(0, "c0", undef, 40), "alternative block below the checkpoint processed");
ok(!skip_scripts(), "validation stays full");
is(QBitcoin::Block->best_block->hash, "b2", "best block unchanged");

done_testing();
