package QBitcoin::Block::Validate;
use warnings;
use strict;
use feature 'state';

# Check block chain
# Check block time
# Validate all transactions
# Total amount of all fees (except coinbase) should be equal to the (minus) reward for the block validation

use Time::HiRes;
use List::Util qw(sum0);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ValueUpgraded qw(level_by_total);
use QBitcoin::Log;
use QBitcoin::Transaction;
use QBitcoin::MinFee qw(min_fee);
use Role::Tiny;

sub validate {
    my $block = shift;

    my $now = Time::HiRes::time();
    $now >= $block->time
        or return "Block time " . $block->time . " is too early for now";
    my $merkle_root = $block->calculate_merkle_root;
    $block->merkle_root eq $merkle_root
        or return "Incorrect merkle root " . unpack("H*", $block->merkle_root) . " expected " . unpack("H*", $merkle_root);
    if (!$block->prev_hash || $block->prev_hash eq ZERO_HASH) {
        if (!$config->{regtest}) {
            my $genesis_hash = $config->{testnet} ? GENESIS_HASH_TESTNET : GENESIS_HASH;
            $block->hash eq $genesis_hash
                or return "Incorrect genesis block hash " . unpack("H*", $block->hash) . ", must be " . unpack("H*", $genesis_hash);
            $block->upgraded = 0; # Genesis block has no upgrades
            $block->reward_fund = 0;
            $block->size = sum0(map { $_->size } @{$block->transactions});
            $block->min_fee = 0;
            return ""; # Not needed to validate genesis block with correct hash
        }
    }
    state $genesis_time = $config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME;
    if (!@{$block->transactions} && (timeslot($block->time) - $genesis_time) / BLOCK_INTERVAL % FORCE_BLOCKS) {
        return "Empty block";
    }
    if (@{$block->transactions} > MAX_TX_IN_BLOCK) {
        return "Too many transactions in block: " . @{$block->transactions} . " (max " . MAX_TX_IN_BLOCK . ")";
    }
    my $block_size = sum0(map { $_->size } @{$block->transactions});
    if ($block_size > MAX_BLOCK_SIZE) {
        return "Block size is too big: $block_size (max " . MAX_BLOCK_SIZE . ")";
    }
    my $fee = 0;
    my $stake_reward = 0;
    my %tx_in_block;
    my $empty_tx = 0;
    my $low_fee_tx = 0;
    my $min_fee = min_fee($block->prev_block, $block_size);
    my $upgraded = $block->prev_block ? $block->prev_block->upgraded // 0 : 0;
    my $min_block_fee;
    my $was_standard;
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
        if ($transaction->is_coinbase) {
            $fee += $transaction->fee;
            if ($was_standard && !$config->{regtest}) {
                return "Coinbase transaction " . $transaction->hash_str . " must not be after standard transaction $was_standard";
            }
        }
        elsif ($transaction->is_standard) {
            $fee += $transaction->fee;
            my $tx_fee_per_kb = int($transaction->fee * 1024 / $transaction->size);
            if ($tx_fee_per_kb < $min_fee || $transaction->fee == 0) {
                if (++$low_fee_tx > MAX_EMPTY_TX_IN_BLOCK) {
                    return "Too many low-fee transactions";
                }
                ++$empty_tx if $transaction->fee == 0;
            }
            else {
                $min_block_fee = $tx_fee_per_kb if !defined($min_block_fee) || $tx_fee_per_kb < $min_block_fee;
            }
            $was_standard = $transaction->hash_str;
        }
        elsif ($transaction->is_stake) {
            if (keys %tx_in_block != 1) {
                return "Stake transaction " . $transaction->hash_str . " must be the first transaction in the block";
            }
            $stake_reward = -$transaction->fee; # fee is negative for stake transactions
        }
        else {
            return "Transaction " . $transaction->hash_str . " is not a coinbase, stake or standard transaction";
        }
    }
    my $block_reward;
    if (!$config->{regtest} && $block->time < 1752962400) { # 2025-07-20
        my $coinbase_fee = sum0 map { $_->fee } grep { $_->is_coinbase } @{$block->transactions};
        $block_reward = (ref $block)->reward($block->prev_block, $coinbase_fee) + $fee - $coinbase_fee;
    }
    else {
        $block_reward = (ref $block)->reward($block->prev_block, $fee);
    }
    # There are no block rewards for empty blocks
    if ($empty_tx >= @{$block->transactions} - 1 && (timeslot($block->time) - $genesis_time) / BLOCK_INTERVAL % FORCE_BLOCKS) {
        $block_reward = 0;
    }
    $stake_reward == $block_reward
        or return "Incorrect stake reward for block " . $block->height . ": $stake_reward, expected $block_reward";
    $block->upgraded = $upgraded;
    $block->reward_fund = $block->prev_block ? $block->prev_block->reward_fund + $fee - $block_reward : 0;
    $block->size = $block_size;
    $block->min_fee = $block_size > MAX_BLOCK_SIZE / 2 ? $min_block_fee : $min_fee;
    return "";
}

sub validate_chain {
    my $block = shift;

    my $fail_tx;
    my $can_consume = 1; # Can validator consume transaction fee? No if stake transaction has no inputs
    for (my $num = 0; $num < @{$block->transactions}; $num++) {
        my $tx = $block->transactions->[$num];
        if (defined($tx->block_height) && $tx->block_height != $block->height) {
            Warningf("Transaction %s included in blocks %u and %u", $tx->hash_str, $tx->block_height, $block->height);
            $fail_tx = $tx->hash;
            last;
        }
        if (my $coinbase = $tx->up) {
            if ($coinbase->tx_out && $coinbase->tx_out ne $tx->hash) {
                Warningf("Coinbase transaction %s has already been spent in %s", $tx->hash_str, $coinbase->tx_out_str);
                $fail_tx = $tx->hash;
                last;
            }
        }
        if (!@{$tx->in} && !$tx->coins_created) {
            if ($num > 0) {
                Warningf("Transaction %s has no inputs", $tx->hash_str);
                $fail_tx = $tx->hash;
                last;
            }
            # Stake transaction without inputs allowed only if the block has no (non-coinbase) transactions with positive fee
            $can_consume = 0;
        }
        elsif (!$can_consume && $tx->fee > 0 && !$tx->coins_created) {
            Warningf("Transaction %s has fee but block validator can't consume it", $tx->hash_str);
            $fail_tx = $tx->hash;
            last;
        }
        foreach my $in (@{$tx->in}) {
            my $txo = $in->{txo};
            # It's possible that $txo->tx_out already set for rebuild blockchain loaded from local database
            if ($txo->tx_out && $txo->tx_out ne $tx->hash) {
                # double-spend; drop this branch, return to old best branch and decrease reputation for peer $block->received_from
                Warningf("Double spend for transaction output %s:%u: first in transaction %s, second in %s, block from %s",
                    $txo->tx_in_str, $txo->num, $txo->tx_out_str, $tx->hash_str,
                    $block->received_from ? $block->received_from->peer->id : "me");
                $fail_tx = $tx->hash;
                last;
            }
            elsif (my $tx_in = QBitcoin::Transaction->get($txo->tx_in)) {
                # Transaction with this output must be already confirmed (in the same best branch)
                # Stored (not cached) transactions are always confirmed, not needed to load them
                if (!defined($tx_in->block_height)) {
                    Warningf("Unconfirmed input %s:%u for transaction %s, block from %s",
                        $txo->tx_in_str, $txo->num, $tx->hash_str,
                        $block->received_from ? $block->received_from->peer->id : "me");
                    $fail_tx = $tx->hash;
                    last;
                }
            }
        }
        last if $fail_tx;
        $tx->confirm($block, $num) if $tx->is_cached;
    }

    if (!$fail_tx) {
        my $self_weight = $block->self_weight;
        if (!defined($self_weight)) {
            $fail_tx = "block"; # does not match any transaction hash
        }
        elsif ($self_weight + ( $block->prev_block ? $block->prev_block->weight : 0 ) != $block->weight) {
            Warningf("Incorrect weight for block %s: %Lu != %Lu", $block->hash_str,
                $block->weight, $self_weight + ( $block->prev_block ? $block->prev_block->weight : 0 ));
            $fail_tx = "block";
        }
    }
    if ($fail_tx) {
        # It's not possible to include a tx twice in the same block, it's checked on block validation
        foreach my $tx (@{$block->transactions}) { # TODO: Do we need reverse order for unconfirm here?
            last if $fail_tx eq $tx->hash;
            $tx->unconfirm() if $tx->is_cached;
        }
    }
    return $fail_tx;
}

1;
