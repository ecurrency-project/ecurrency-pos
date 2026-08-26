#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Generate;
use QBitcoin::Generate::Control;
use QBitcoin::ProtocolState qw(blockchain_synced mempool_synced);

# Generate::restake_for_tx is the single re-stake trigger for every transaction admitted
# to the mempool, whatever its source (peer, RPC sendrawtransaction, producer): a new
# fee-paying transaction reopens generation (generate_new) when the current best block is
# ours or carries no stake, so our stake can claim the slot's reward. The 2026-08-26
# h1855673 incident: the trigger lived only in the peer path, an RPC-submitted fee tx was
# announced to everyone, and the only validator unable to restake on it was our own node.

$config->{regtest} = 1;

{
    package FakeTx;
    sub new { my ($class, %f) = @_; return bless { fee => 0, up => undef, %f }, $class }
    sub fee { $_[0]->{fee} }
    sub up  { $_[0]->{up} }

    package FakeStakeTx;
    sub is_stake { 1 }

    package FakePayTx;
    sub is_stake { 0 }

    package FakeBlock;
    sub new { my ($class, %f) = @_; return bless { %f }, $class }
    sub received_from { $_[0]->{received_from} }
    sub transactions  { $_[0]->{transactions} }
}

my $best_block;
my @staked_utxo = (1);
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('best_block', sub { $best_block });
my $txo_module = Test::MockModule->new('QBitcoin::TXO');
$txo_module->mock('staked_utxo', sub { @staked_utxo });

blockchain_synced(1);
mempool_synced(1);

sub triggered {
    my ($tx) = @_;
    QBitcoin::Generate::Control->generated_time(12345);
    QBitcoin::Generate->restake_for_tx($tx);
    return !defined(QBitcoin::Generate::Control->generated_time);
}

my $stakeless_peer = FakeBlock->new(received_from => "peer", transactions => [ bless({}, 'FakePayTx') ]);
my $staked_peer    = FakeBlock->new(received_from => "peer", transactions => [ bless({}, 'FakeStakeTx') ]);
my $our_staked     = FakeBlock->new(received_from => undef,  transactions => [ bless({}, 'FakeStakeTx') ]);

$best_block = $stakeless_peer;
ok(triggered(FakeTx->new(fee => 3)), "paid tx triggers regen when the best peer block has no stake");
ok(!triggered(FakeTx->new(fee => 0)), "zero-fee tx does not trigger");
ok(!triggered(FakeTx->new(fee => -10)), "stake tx (negative fee) does not trigger");
ok(triggered(FakeTx->new(fee => 0, up => 1)), "upgrade coinbase triggers even with zero fee");

$best_block = $staked_peer;
ok(!triggered(FakeTx->new(fee => 3)), "no trigger when the best peer block already carries a stake");

$best_block = $our_staked;
ok(triggered(FakeTx->new(fee => 3)), "paid tx triggers regen when the best block is ours (rebuild/sibling decision is generate()'s)");

$best_block = $stakeless_peer;
@staked_utxo = ();
ok(!triggered(FakeTx->new(fee => 3)), "no trigger without staked utxo (nothing to stake)");
@staked_utxo = (1);

blockchain_synced(0);
ok(!triggered(FakeTx->new(fee => 3)), "no trigger while blockchain is not synced");
blockchain_synced(1);
mempool_synced(0);
ok(!triggered(FakeTx->new(fee => 3)), "no trigger while mempool is not synced");
mempool_synced(1);

$best_block = undef;
ok(!triggered(FakeTx->new(fee => 3)), "no trigger without any best block");

done_testing();
