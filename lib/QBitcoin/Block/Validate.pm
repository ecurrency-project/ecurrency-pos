package QBitcoin::Block::Validate;
use warnings;
use strict;
use feature 'state';

# Check block chain
# Check block time
# Validate all transactions
# Amount of all commissions should be 0

use Time::HiRes;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ValueUpgraded qw(level_by_total);
use Role::Tiny;

sub validate {
    my $block = shift;

    my $now = Time::HiRes::time();
    $now >= $block->time
        or return "Block time " . $block->time . " is too early for now";
    if (!$block->prev_hash || $block->prev_hash eq ZERO_HASH) {
        if (!$config->{regtest}) {
            my $genesis_hash = $config->{testnet} ? GENESIS_HASH_TESTNET : GENESIS_HASH;
            $block->hash eq $genesis_hash
                or return "Incorrect genesis block hash " . unpack("H*", $block->hash) . ", must be " . unpack("H*", $genesis_hash);
            $block->upgraded = 0; # Genesis block has no upgrades
            return ""; # Not needed to validate genesis block with correct hash
        }
    }
    state $genesis_time = $config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME;
    if (!@{$block->transactions} && (timeslot($block->time) - $genesis_time) / BLOCK_INTERVAL % FORCE_BLOCKS) {
        return "Empty block";
    }
    my $merkle_root = $block->calculate_merkle_root;
    $block->merkle_root eq $merkle_root
        or return "Incorrect merkle root " . unpack("H*", $block->merkle_root) . " expected " . unpack("H*", $merkle_root);
    my $fee = 0;
    my %tx_in_block;
    my $empty_tx = 0;
    my $upgraded = $block->prev_block ? $block->prev_block->upgraded // 0 : 0;
    foreach my $transaction (@{$block->transactions}) {
        if ($tx_in_block{$transaction->hash}++) {
            return "Transaction " . $transaction->hash_str . " included in the block twice";
        }
        if ($transaction->valid_for_block($block) != 0) {
            return "Transaction " . $transaction->hash_str . " can't be included in block " . $block->height;
        }
        if (UPGRADE_POW && $transaction->coins_created) {
            if ($transaction->upgrade_level != level_by_total($upgraded += $transaction->up->value_btc)) {
                return "Incorrect upgrade level for transaction " . $transaction->hash_str;
            }
        }
        # NB: we do not check that the $txin is unspent in this branch;
        # we will check this on include this block into the best branch
        if ($transaction->fee == 0) {
            if (!$transaction->coins_created) {
                if (++$empty_tx > MAX_EMPTY_TX_IN_BLOCK) {
                    return "Too many empty transactions";
                }
            }
        }
        else {
            $fee += $transaction->fee;
        }
    }
    $fee == -(ref $block)->reward($block->height)
        or return "Total block fee is $fee (not " . -(ref $block)->reward($block->height) . ")";
    $block->upgraded = $upgraded;
    return "";
}

1;
