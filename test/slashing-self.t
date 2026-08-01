#! /usr/bin/env perl
use warnings;
use strict;

# Regression: a node whose generated block did NOT become best (lost on weight, freed,
# never announced) re-staked the same UTXO in the same timeslot with a different
# block_sign_data; the equivocation detector in Block::Receive observes the node's own
# blocks too, so the node built a slashing transaction against itself.
#
# The signed stake is recorded in the published registry when it is signed and saved
# (not only when its block enters the best branch), and when the block loses without
# ever being announced the commitment is voided again (unrecord_stake + forget_stake):
# the signature never left the node, so re-staking the same slot with the same UTXO is
# safe - and must produce a block, not a self-slashing.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize qw(block_hash);
use QBitcoin::Test::Send qw(send_tx send_block $last_tx);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Transaction;
use QBitcoin::Block;
use QBitcoin::Generate;
use QBitcoin::Generate::Control;
use QBitcoin::Slashing;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::Coins;
use QBitcoin::ProtocolState qw(blockchain_synced);

$config->{regtest} = 1;
$config->{genesis} = 1;
$config->{genesis_reward} = GENESIS_REWARD;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });

my $static_reward = 200000000;
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { $static_reward });

my $pk = generate_keypair(CRYPT_ALGO_ECDSA);
my ($address) = addresses_by_pubkey($pk->pubkey_by_privkey, CRYPT_ALGO_ECDSA);
my $myaddr = QBitcoin::MyAddress->create({
    private_key => wallet_import_format($pk->pk_serialize),
    address     => $address,
    staked      => 1,
});

QBitcoin::Coins->init();

my $time = GENESIS_TIME;
block_hash("a0");
QBitcoin::Generate->generate($time)
    or die "genesis block not generated\n";

# A heavy peer block a1 confirms a coin on our staked address.
my $stake_tx = send_tx(-$static_reward);
undef $last_tx;
my $tx  = send_tx(0);
my $tx2 = send_tx(0, $tx, $myaddr->redeem_script);
send_block(1, "a1", "a0", 50, $stake_tx, $tx, $tx2);
is(QBitcoin::Block->best_block->hash, "a1", "heavy peer block a1 is the tip");

blockchain_synced(1);

# A fee-paying transaction so our block has a reward to stake for.
send_tx(10, undef);

my $slot = timeslot($time + BLOCK_INTERVAL);
ok(!QBitcoin::Generate::Control->staked_slot($slot), "slot not staked yet");

# Our competing block b1 for height 1 loses on weight against a1 and is freed. The
# stake was signed but never left the node, so its commitment must be voided again.
block_hash("b1");
my $b1 = QBitcoin::Generate->generate($time + BLOCK_INTERVAL);
ok($b1, "our block b1 generated");
my $stake1 = $b1 && @{$b1->transactions} ? $b1->transactions->[0] : undef;
ok($stake1 && $stake1->is_stake && @{$stake1->in}, "b1 carries a stake with real inputs");
is(QBitcoin::Block->best_block->hash, "a1", "b1 lost on weight, a1 is still the tip");
ok(!QBitcoin::Generate::Control->staked_slot($slot),
    "the never-published stake is forgotten, the slot is stakeable again");

# A new mempool transaction changes the tx set, so the regenerated block signs a
# different block_sign_data with the same UTXO. This is safe (the first signature is
# gone forever) and must yield a block - not a slashing transaction against ourselves.
send_tx(10, undef);
block_hash("c1");
my $c1 = QBitcoin::Generate->generate($time + BLOCK_INTERVAL);
ok($c1, "second block c1 generated in the same slot");
my $stake2 = $c1 && @{$c1->transactions} ? $c1->transactions->[0] : undef;
ok($stake2 && $stake2->is_stake && @{$stake2->in}, "c1 carries a stake with real inputs");
is($stake2 && $stake2->in->[0]{txo}->key, $stake1->in->[0]{txo}->key,
    "c1 re-staked the same UTXO");
isnt($stake2 && $stake2->block_sign_data, $stake1->block_sign_data,
    "...signing a different block");

my @slashing = grep { $_->is_slashing } QBitcoin::Transaction->mempool_list();
is(scalar(@slashing), 0, "no slashing transaction built - the node did not slash itself");
ok(!QBitcoin::Slashing->is_banned_stake($stake1, $slot), "our stake UTXO is not banned");
is(QBitcoin::Block->best_block->hash, "a1", "a1 remains the tip");

# Control: when our block DOES become best (published), its stake stays recorded.
# Generate in a slot after a1's own timeslot so the block builds on top of a1.
my $time2 = $time + BLOCK_INTERVAL * FORCE_BLOCKS + BLOCK_INTERVAL;
my $slot2 = timeslot($time2);
block_hash("b2");
my $b2 = QBitcoin::Generate->generate($time2);
ok($b2, "block b2 generated in the next slot");
is(QBitcoin::Block->best_block->hash, "b2", "b2 entered the best branch");
ok(QBitcoin::Generate::Control->staked_slot($slot2),
    "the published stake stays recorded");

done_testing();
