#! /usr/bin/env perl
use warnings;
use strict;

# The signature of a stake transaction covers the block, so its input scripts are executed
# again for each block the transaction is included in. OP_CHECKSIG gives FALSE for a
# signature made for another block, it does not fail the script, so a script can take
# another branch there and require a time lock. The locks found for one block must not be
# kept for the next one: a block is valid or not whatever blocks with the same stake
# transaction the node has checked before.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(make_block send_block send_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script::Util qw(pack_int);

#$config->{debug} = 1;
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

my $key = generate_keypair(CRYPT_ALGO_ECDSA);

# The locks are not reached in the test: its blocks are at heights 0 .. 2,
# one per forced-block interval (see QBitcoin::Test::Send::make_block)
my $lock_blocks = 1000;
my %lock = (
    "absolute time"   => op_pushdata(pack_int(GENESIS_TIME + $lock_blocks * BLOCK_INTERVAL * FORCE_BLOCKS)) . OP_CHECKLOCKTIMEVERIFY,
    "absolute height" => op_pushdata(pack_int($lock_blocks)) . OP_CHECKLOCKTIMEVERIFY,
    "relative time"   => op_pushdata(pack_int(QBitcoin::Script::QBT_SEQUENCE_LOCKTIME_TYPE_FLAG | $lock_blocks * FORCE_BLOCKS)) . OP_CHECKSEQUENCEVERIFY,
    "relative height" => op_pushdata(pack_int($lock_blocks)) . OP_CHECKSEQUENCEVERIFY,
);

# The coin is spent without a lock by a transaction signed with the key and only after the
# lock otherwise. A stake transaction signs the block, so its signature fits one block only.
sub lock_script {
    my ($lock) = @_;
    return op_pushdata($key->pubkey_by_privkey) . OP_CHECKSIG . OP_NOTIF . $lock . OP_DROP . OP_ENDIF . OP_1;
}

my $fee_tx; # the reward of the blocks with a stake transaction

# The stake transaction spending the coin, signed for the block
sub make_stake {
    my ($coin, @block) = @_;
    my $stake = make_tx($coin, -1);
    # The data signed for a block does not cover its stake transaction, so take it from the block
    # with the unsigned one: the test does not depend on the format of the data
    $stake->block_sign_data = make_block(@block, $stake, $fee_tx)->sign_data;
    $stake->in->[0]->{siglist} = [ pack("CC", SIGHASH_ALL, CRYPT_ALGO_ECDSA) . $key->signature($stake->sign_hash(0, SIGHASH_ALL)) ];
    $stake->calculate_hash;
    $_->tx_in = $stake->hash foreach @{$stake->out};
    return $stake;
}

# Send the block and its stake transaction. Does the node take the block as a valid one?
sub block_accepted {
    my ($stake, @block) = @_;
    send_block(@block, $stake, $fee_tx);
    return QBitcoin::Block->block_pool($block[1]) ? 1 : 0;
}

# height, hash, prev_hash, weight, $tx
my %coin = map { $_ => send_tx(0, undef, lock_script($lock{$_})) } sort keys %lock;
my $funds = send_tx(0, undef);
send_block(0, "a0", undef, 100, @coin{sort keys %lock}, $funds);
$fee_tx = send_tx(1, $funds);
send_block(1, "x1", "a0", 200, send_tx(0, undef));
is(QBitcoin::Block->blockchain_height, 1, "the coins are confirmed");

foreach my $name (sort keys %lock) {
    (my $id = $name) =~ tr/ /_/;
    # Block A is signed by the stake transaction, block A2 is its twin with the same signed
    # data (the same parent, time and transactions); block B is on another branch
    my @block_a  = (1, "a_$id",  "a0", 110);
    my @block_a2 = (1, "a2_$id", "a0", 120);
    my @block_b  = (2, "b_$id",  "x1", 300);
    my $stake = make_stake($coin{$name}, @block_a);

    ok(!block_accepted($stake, @block_b),  "$name lock: locked in the block the stake does not sign");
    ok( block_accepted($stake, @block_a),  "$name lock: no lock in the block the stake signs");
    ok(!block_accepted($stake, @block_b),  "$name lock: locked in the other block after the check for the signed one");
    ok( block_accepted($stake, @block_a2), "$name lock: no lock in the signed block after the check for the other one");
}

done_testing();
