#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize; # redefines UPGRADE_POW to 0 before transaction modules load
use QBitcoin::Test::MakeTx;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Transaction;
use QBitcoin::TXO;

$config->{regtest} = 1;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });

# The mempool limits are compile-time constants (MAX_MEMPOOL_SIZE is 100 MB), so the
# transactions get huge explicit sizes to hit the limits with a few of them.
# Each tx is 30 MB: 3 txs fit the mempool, the 4th passes want_tx() only if it is
# better than the worst one, eviction must bring the size back under the limit.
use constant TX_SIZE => 30*1024*1024;

sub make_mempool_tx {
    my ($prev_tx, $fee) = @_;
    my $tx = make_tx($prev_tx, $fee);
    $tx->{size} = TX_SIZE;
    $tx->{received_time} = time();
    $tx->save();
    return $tx;
}

# Confirmed-like sources: coinbase txs are not mempool-limited and not evictable
my @base = map { my $tx = make_tx(undef, 0); $tx->save(); $tx } (1..5);

my $parent = make_mempool_tx($base[0], 10);     # awful own feerate
my $child  = make_mempool_tx($parent, 20000);   # pays for the parent (CPFP)
my $mid1   = make_mempool_tx($base[1], 5000);
my $mid2   = make_mempool_tx($base[2], 3000);   # worst by descendant score

# Admission control: mempool is over the size limit now
my $bad = make_tx($base[3], 3);
$bad->{size} = TX_SIZE;
ok(!QBitcoin::Transaction::want_tx($bad), "tx worse than the worst evictable rejected");
my $good = make_tx($base[4], 8000);
$good->{size} = TX_SIZE;
ok(QBitcoin::Transaction::want_tx($good), "tx better than the worst evictable accepted");

QBitcoin::Transaction::evict_mempool();

is(QBitcoin::Transaction->get($mid2->hash), undef, "tx with the worst descendant score evicted");
ok(QBitcoin::Transaction->get($parent->hash), "CPFP parent with awful own feerate kept");
ok(QBitcoin::Transaction->get($child->hash), "CPFP child kept");
ok(QBitcoin::Transaction->get($mid1->hash), "better independent tx kept");

# Without the expensive child the parent is the worst; it goes together
# with its dependent chain
my $grandchild = make_mempool_tx($child, 3500);
QBitcoin::Transaction->get($child->hash)->drop(); # drops $grandchild too
is(QBitcoin::Transaction->get($grandchild->hash), undef, "descendants dropped with the parent");
my $mid3 = make_mempool_tx($base[3], 3000);
my $mid4 = make_mempool_tx($base[4], 4000); # push the mempool over the size limit again
QBitcoin::Transaction::evict_mempool();
is(QBitcoin::Transaction->get($parent->hash), undef, "parent without paying descendants evicted first");
ok(QBitcoin::Transaction->get($mid1->hash) && QBitcoin::Transaction->get($mid3->hash)
    && QBitcoin::Transaction->get($mid4->hash), "independent txs kept");

done_testing();
