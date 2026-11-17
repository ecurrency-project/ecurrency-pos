#! /usr/bin/env perl
use warnings;
use strict;

# A slashing transaction is accepted to a block only if the stake it punishes could win a
# block: the weight of the outputs it spends, multiplied by SLASHING_BARRIER_MARGIN, must be
# not less than the weight of the lightest of the last SLASHING_BARRIER_STAKES stakes before
# the block. Otherwise equivocation evidence made of any coins would be megabytes in the
# blockchain for the fine of a few satoshi.
#
# While a slashing transaction can not be included, it is not kept in the mempool (unless a
# pending block contains it), not taken into a block we generate, and the stake it punishes
# is not banned: there would be nothing to replace its block with.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Test::Send qw(send_raw_tx $connection);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Block;
use QBitcoin::Slashing;
use QBitcoin::Mempool;
use QBitcoin::Generate;

$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

blockchain_synced(1);

my $script     = op_pushdata(pack("v", 1)) . OP_DROP . OP_1;
my $scripthash = hash160($script);

# Every block of the test is a forced one, FORCE_BLOCKS timeslots after the previous; the
# last of them is not later than now
my $base_slot = (int((time() - GENESIS_TIME) / BLOCK_INTERVAL / FORCE_BLOCKS) - 10) * FORCE_BLOCKS;
sub block_time { GENESIS_TIME + ($base_slot + $_[0] * FORCE_BLOCKS) * BLOCK_INTERVAL }

sub finish_tx {
    my ($tx) = @_;
    $tx->calculate_hash;
    my $num = 0;
    foreach my $out (@{$tx->out}) {
        $out->tx_in = $tx->hash;
        $out->num = $num++;
    }
    return $tx;
}

sub new_out {
    my ($value) = @_;
    return QBitcoin::TXO->new_txo({ value => $value, scripthash => $scripthash, data => "" });
}

# Coins confirmed in the first block: the weight of each is its value times its age in timeslots / 65536
sub coins {
    my @values = @_;
    return finish_tx(QBitcoin::Transaction->new(
        in            => [],
        out           => [ map { new_out($_) } @values ],
        fee           => 0,
        tx_type       => TX_TYPE_COINBASE,
        coins_created => sum0(@values),
    ));
}

sub spend {
    my ($coin, $fee, $tx_type) = @_;
    $coin->{redeem_script} = $script;
    return finish_tx(QBitcoin::Transaction->new(
        in      => [ { txo => $coin, siglist => [] } ],
        out     => [ new_out($coin->value - $fee) ],
        fee     => $fee,
        tx_type => $tx_type,
    ));
}

# The stake of a block built on the best one, with the reward for the given transactions
sub stake {
    my ($coin, $time, @tx) = @_;
    my $reward = QBitcoin::Block->reward(QBitcoin::Block->best_block, sum0(map { $_->fee } @tx), $time);
    return spend($coin, -$reward, TX_TYPE_STAKE);
}

# Slashing transaction for the coin: the evidence is two stakes of it signing different blocks
sub slashing {
    my ($coin, $time) = @_;
    $coin->{redeem_script} = $script;
    my @stakes = map {
        finish_tx(QBitcoin::Transaction->new(
            in              => [ { txo => $coin, siglist => [] } ],
            out             => [ new_out($coin->value) ],
            fee             => 0,
            tx_type         => TX_TYPE_STAKE,
            block_sign_data => $_->[0] . pack("N", $time) . $_->[1],
        ))
    } [ "\x11" x 32, "\xa1" x 32 ], [ "\x22" x 32, "\xb2" x 32 ];
    return QBitcoin::Slashing->new_tx(@stakes);
}

# Block hashes of the real length: the stake signs the hash of the previous block
sub block_id { $_[0] . "." x (32 - length($_[0])) }

sub send_block {
    my ($height, $hash, $prev_hash, $weight, @tx) = @_;
    $_ = block_id($_) foreach grep { defined } $hash, $prev_hash;
    my $block = QBitcoin::Block->new(
        time         => block_time($height),
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => \@tx,
        weight       => $weight,
    );
    $block->add_tx($_) foreach @tx;
    $block->merkle_root = $block->calculate_merkle_root();
    block_hash($hash);
    $connection->protocol->command("block");
    return $connection->protocol->cmd_block($block->serialize);
}

sub best_height { QBitcoin::Block->blockchain_height }
sub in_mempool  { !!QBitcoin::Transaction->get($_[0]->hash) }

# The weight of a coin is its value multiplied by its age in timeslots and divided by 65536,
# and a coin with more decimals may count its value in larger units. Take the unit from
# the weight of a coin which is 65536 timeslots old.
$transaction_module->mock('txo_time', sub { GENESIS_TIME });
my $probe = QBitcoin::TXO->new_txo({ tx_in => ZERO_HASH, num => 0, value => 100_000_000, scripthash => $scripthash, data => "" });
my $unit = $probe->value / spend($probe, -1, TX_TYPE_STAKE)->stake_weight(QBitcoin::Block->new(time => GENESIS_TIME + 0x10000 * BLOCK_INTERVAL));
$transaction_module->unmock('txo_time');

my $U = 0x10000; # a coin of this many units gets the weight 1 for each timeslot of its age
my %value = (
    fee   => 1000,
    s2    => 1 * $U,  # stakes of the blocks 2..6: weights 200, 3000, 2000, 10000, 6000
    s3    => 10 * $U,
    s4    => 5 * $U,
    s5    => 20 * $U,
    s6    => 10 * $U,
    s7a   => 10 * $U,
    s7b   => 10 * $U,
    s8a   => 10 * $U,
    b499  => 46811,   # weight 499 in the block 7, where 500 is required
    b500  => 46812,   # weight 500 there
    light => 20000,   # weight 305..336 now, 244 in the block 8
    late  => 40000,   # weight 610..671 now, but 488 in the block 8
    heavy => 10 * $U, # weight 9000 in the block 9
);
my @names = sort keys %value;
my $coins = coins(map { $_ * $unit } @value{@names});
my %coin = map { $names[$_] => $coins->out->[$_] } 0 .. $#names;

send_raw_tx($coins);
send_block(0, "a0", undef, 50, $coins);
my $more_coins = coins(1);
send_raw_tx($more_coins);
send_block(1, "a1", "a0", 60, $more_coins); # no stake in this block
is(best_height(), 1, "blocks without a stake accepted");

# The first staked block gets its reward from a fee
my $fee_tx = spend($coin{fee}, 600, TX_TYPE_STANDARD);
send_raw_tx($fee_tx);
my $stake = stake($coin{s2}, block_time(2), $fee_tx);
send_raw_tx($stake);
send_block(2, "a2", "a1", 70, $stake, $fee_tx);
foreach my $height (3 .. 6) {
    $stake = stake($coin{"s$height"}, block_time($height));
    send_raw_tx($stake);
    send_block($height, "a$height", "a" . ($height - 1), 50 + 10 * $height, $stake);
}
is(best_height(), 6, "staked blocks accepted");

# --- the reference: the lightest of the last four stakes ---------------------

is(QBitcoin::Block->best_block(4)->min_stake_weight, 200, "blocks without a stake are skipped, three stakes found");
is(QBitcoin::Block->best_block(5)->min_stake_weight, 200, "the lightest of four stakes");
is(QBitcoin::Block->best_block(6)->min_stake_weight, 2000, "a stake before the last four does not count");
is(QBitcoin::Block->best_block(0)->min_stake_weight, 0, "no stakes yet: nothing is required");

my $b6 = QBitcoin::Block->best_block(6);
my ($tx499, $tx500, $tx_light) = map { slashing($coin{$_}, block_time(7)) } qw(b499 b500 light);
is($tx499->slashing_weight(block_time(7)), 499, "weight of the outputs of a slashing tx");
ok(!$b6->slashing_weight_ok($tx499, block_time(7)), "a quarter of the lightest stake is required: 499 * 4 < 2000");
ok($b6->slashing_weight_ok($tx500, block_time(7)), "500 * 4 = 2000 is enough");
ok($b6->slashing_weight_ok($tx499, block_time(8)), "the same outputs are heavier in a later block");
ok(QBitcoin::Block->best_block(5)->slashing_weight_ok($tx499, block_time(6)), "and enough after lighter stakes");

# --- the mempool ---------------------------------------------------------------

send_raw_tx($tx_light);
ok(!in_mempool($tx_light), "slashing tx of a stake too light to win a block is not accepted to the mempool");
ok(!QBitcoin::Slashing->is_banned_stake(spend($coin{light}, -1, TX_TYPE_STAKE), block_time(7)),
    "and its stake is not banned");
send_raw_tx($tx499);
ok(in_mempool($tx499), "slashing tx which is heavy enough for the next block now is accepted");
ok(!QBitcoin::Generate::_have_weight_tx($b6, block_time(7)), "it is not a reason for a sibling block where it is too light");
ok(QBitcoin::Generate::_have_weight_tx($b6, block_time(8)), "but it is where it is heavy enough");
send_raw_tx($tx500);
ok(in_mempool($tx500), "the heavier one is accepted too");

my %chosen = map { $_->hash => 1 } QBitcoin::Mempool->choose_for_block(1000, block_time(7), $b6, 1);
ok(!$chosen{$tx499->hash}, "slashing tx too light for the block is not chosen for it");
ok($chosen{$tx500->hash}, "the one which is heavy enough is chosen");

# --- the consensus rule --------------------------------------------------------

$stake = stake($coin{s7a}, block_time(7), $tx499);
send_raw_tx($stake);
isnt(send_block(7, "b7", "a6", 120, $stake, $tx499), 0, "block with a slashing tx of a too light stake is rejected");
is(best_height(), 6, "it is not in the best branch");
ok(in_mempool($tx499), "the slashing tx stays in the mempool: it fits a later block");

$stake = stake($coin{s7b}, block_time(7), $tx500);
send_raw_tx($stake);
is(send_block(7, "a7", "a6", 120, $stake, $tx500), 0, "block with a slashing tx of a stake heavy enough is accepted");
is(best_height(), 7, "it is the best block");
is(QBitcoin::Block->best_block(7)->min_stake_weight, 2000, "the weight of a slashing tx is not the weight of a stake");

# --- a slashing tx requested for a block -----------------------------------------

$tx_light = slashing($coin{light}, block_time(8));
$stake = stake($coin{s8a}, block_time(8), $tx_light);
send_raw_tx($stake);
is(send_block(8, "b8", "a7", 130, $stake, $tx_light), 0, "block with an unknown slashing tx is waiting for it");
is(best_height(), 7, "the block is pending");
send_raw_tx($tx_light);
ok(in_mempool($tx_light), "slashing tx is accepted for the block which contains it");
is(best_height(), 7, "the block with it is rejected: the stake is too light");
QBitcoin::Transaction->cleanup_mempool();
ok(!in_mempool($tx_light), "and the slashing tx is dropped: it can not be included");
ok(in_mempool($tx499), "the one which can be included is not");

# --- the ban -------------------------------------------------------------------

# The slashing tx is heavy enough for the next block now, but not for a block of the
# timeslot the stake signed: this block of the stake is not rejected
my $tx_late = slashing($coin{late}, block_time(8));
send_raw_tx($tx_late);
ok(in_mempool($tx_late), "slashing tx is accepted while its outputs are unspent and heavy enough now");
my $stake8 = stake($coin{late}, block_time(8));
ok(QBitcoin::Slashing->is_banned_stake($stake8, block_time(8)), "we hold the evidence against the stake");
send_raw_tx($stake8);
is(send_block(8, "a8", "a7", 130, $stake8), 0, "block of the stake is accepted: the slashing tx could not replace it");
is(best_height(), 8, "it is the best block");
is(QBitcoin::Slashing->banned_height_in_best(), undef, "and it is not dropped from the best branch");
is(QBitcoin::Block->best_block(8)->min_stake_weight, 488, "now it is the lightest stake");

# The equivocated block is in the best branch already, then the slashing tx comes
$stake = stake($coin{heavy}, block_time(9));
send_raw_tx($stake);
is(send_block(9, "a9", "a8", 140, $stake), 0, "block of a heavy stake accepted");
my $tx_heavy = slashing($coin{heavy}, block_time(9));
send_raw_tx($tx_heavy);
ok(in_mempool($tx_heavy), "slashing tx is accepted: it can be included instead of the block of the stake");
is(QBitcoin::Slashing->banned_height_in_best(), 9, "the block is to be dropped from the best branch");

# Another stake of the same coin with the same reward: for another block of the same timeslot
sub twin {
    my ($coin, $stake) = @_;
    return finish_tx(QBitcoin::Transaction->new(
        in      => [ { txo => $coin, siglist => [] } ],
        out     => [ new_out($coin->value), new_out(-$stake->fee) ],
        fee     => $stake->fee,
        tx_type => TX_TYPE_STAKE,
    ));
}

# Slashing transactions in the mempool for the coin
sub slashing_of {
    my ($coin) = @_;
    return grep { my $tx = $_; $tx->is_slashing && grep { $_->{txo}->key eq $coin->key } @{$tx->in} }
        QBitcoin::Transaction->mempool_list;
}

my $twin9 = twin($coin{heavy}, $stake);
send_raw_tx($twin9);
isnt(send_block(9, "b9", "a8", 141, $twin9), 0, "another block of the equivocated stake is rejected");
is(QBitcoin::Block->best_block->hash, block_id("a9"), "the best block is the same");

# --- equivocation observed in two blocks -------------------------------------------

# The stake signs the list of the other transactions of its block, so another block of the
# same parent and timeslot is a different one if it has some
my $twin8 = twin($coin{late}, $stake8);
send_raw_tx($twin8);
my $other_tx = coins(2);
send_raw_tx($other_tx);
is(send_block(8, "c8", "a7", 125, $twin8, $other_tx), 0, "another block of the stake too light to be slashed is accepted");
is(scalar(slashing_of($coin{late})), 1, "its equivocation is not reported: no new slashing tx");

# The stakes are weighed in the best branch only, so a block on top of another branch is
# not rejected while it is there
send_raw_tx($twin9); # it was dropped with the rejected block
is(send_block(9, "c9", "c8", 135, $twin9), 0, "block of the equivocated stake on top of another branch is not rejected");
is(QBitcoin::Block->best_block->hash, block_id("a9"), "it is not the best block");
is(scalar(slashing_of($coin{heavy})), 2, "equivocation of the heavy stake is reported: one more slashing tx");

# --- the stakes of the blocks freed from the memory -------------------------------

QBitcoin::Block->store_blocks();
is(QBitcoin::Block->max_db_height, 9, "blocks stored");
QBitcoin::Block->cleanup_old_blocks();
cmp_ok(QBitcoin::Block->min_incore_height, '>', 2, "old blocks freed");
is(QBitcoin::Block->best_block(5)->min_stake_weight, 200, "the stakes of stored blocks are weighed as well");

done_testing();
