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
use QBitcoin::Test::Send qw(send_raw_tx $connection);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Slashing;

# Reproduce the crash "Attempt to override already loaded txo":
#   - stake S2 (spending S1:0) gets into a validated block, so
#     QBitcoin::Slashing->observe(S2) stores it in the %SEEN watch list
#   - the branch is reorged away, blocks are freed, S1 and S2 are dropped
#     from the mempool
#   - the %SEEN snapshot must not pin the real input txo S1:0 in the %TXO
#     cache, otherwise re-receiving S1 dies in TXO::save

#$config->{debug} = 1;
$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

blockchain_synced(1);

# Mempool chain: coinbase C <- stake S1 <- stake S2 (no pending inputs)
my $tx_c  = make_tx(undef, 0);
my $tx_s1 = make_tx($tx_c, -1);
my $tx_s2 = make_tx($tx_s1, -1);

send_raw_tx($tx_c);
send_raw_tx($tx_s1);
send_raw_tx($tx_s2);

{
    my $s2 = QBitcoin::Transaction->get($tx_s2->hash);
    ok($s2, "stake S2 is in the mempool");

    # The block with S2 was validated: Block::Receive calls observe() on its stake
    $s2->{block_sign_data} = "\x11" x 32 . pack("N", timeslot(GENESIS_TIME)) . "\xaa" x 32;
    QBitcoin::Slashing->observe($s2, timeslot(GENESIS_TIME));
    # $s2 goes out of scope here: only the mempool and the %SEEN watch list keep refs
}

# Reorg drops the branch: the stake transactions leave the mempool
QBitcoin::Transaction->get($tx_s1->hash)->drop();
is(QBitcoin::Transaction->get($tx_s1->hash), undef, "S1 dropped from mempool");
is(QBitcoin::Transaction->get($tx_s2->hash), undef, "S2 dropped from mempool");

# The %SEEN watch list may keep the stake evidence, but must not keep
# the real S1:0 txo object registered in the %TXO cache
is(QBitcoin::TXO->get({ tx_out => $tx_s1->hash, num => 0 }), undef,
    "txo S1:0 released from TXO cache");

# Re-receiving S1 (e.g. relayed by another peer) must not die
my $res = eval {
    $connection->protocol->command("tx");
    $connection->protocol->cmd_tx($tx_s1->serialize . "\x00"x16);
};
is($@, '', "re-receiving S1 does not crash");
is($res, 0, "S1 accepted again") if !$@;

done_testing();
