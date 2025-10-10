package QBitcoin::Mempool;
use warnings;
use strict;

# TODO: get transaction weight as fee*age, where age is (time() - $tx->received_time + NN), NN is ~ 10*BLOCK_INTERVAL
# Old transactions will have preferences, and all transactions will be confirmed at one time
# This allow to avoid drop old transactions from the tail of mempool queue
# but transactions with high fee will be confirmed immediately

# TODO: optimize these methods; keep mempool sorted and do not sort it each time

use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::ValueUpgraded qw(level_by_total);
use QBitcoin::MinFee qw(min_fee);

sub want_tx {
    my $class = shift;
    my ($size, $fee) = @_;
    # TODO
    # Consider mempool size and fee/size percentille
    return 1;
}

sub coinbase_list {
    my $class = shift;
    my ($block_time) = @_;
    # coinbase transactions are not limited by block height
    return grep { $_->is_coinbase && defined($_->min_tx_time) && $_->min_tx_time <= $block_time }
        QBitcoin::Transaction->mempool_list();
}

sub choose_for_block {
    my $class = shift;
    my ($size, $block_time, $prev_block, $can_consume) = @_;
    my $block_height = $prev_block ? $prev_block->height+1 : 0;
    my $upgraded_total = $prev_block ? $prev_block->upgraded : 0;
    my @mempool =
        grep { defined($_->min_tx_block_height) && $_->min_tx_block_height <= $block_height &&
               defined($_->min_tx_time) && $_->min_tx_time <= $block_time }
            QBitcoin::Transaction->mempool_list();
    Debugf("Mempool: %s", join(',', map { $_->hash_str } @mempool)) if @mempool;
    if ($block_height) {
        for (my $block = $prev_block->next_block; $block; $block = $block->next_block) {
            push @mempool, @{$block->transactions};
        }
    }
    return () unless @mempool;
    @mempool = sort { compare_tx($a, $b) } @mempool;
    if (!$can_consume) {
        @mempool = grep { $_->fee == 0 || $_->coins_created } @mempool;
    }
    my $low_fee_tx = 0;
    my $tx_in_block = $size ? 1 : 0;
    # It's not possible that input was spent in stake transaction
    # b/c we do not use inputs existing in any mempool transaction for stake tx
    my %spent;
    my %mempool_out; # for allow spend unconfirmed in the same block
    for (my $i=0; $i<=$#mempool; $i++) {
        if (UPGRADE_POW && $mempool[$i]->is_coinbase) {
            my $coinbase = $mempool[$i]->up;
            if ($coinbase->tx_out) {
                # Already confirmed spent (MB not dropped from mempool b/c it included in some other block in alternate branch)
                $mempool[$i] = undef;
                next;
            }
            my $upgrade_level = level_by_total($upgraded_total += $coinbase->value_btc);
            if ($mempool[$i]->upgrade_level != $upgrade_level) {
                # Re-create coinbase transaction with new upgrade level
                my $new_tx = QBitcoin::Transaction->new_coinbase($coinbase, $upgrade_level);
                Debugf("Upgrade level changed %u -> %u, coinbase tx %s replaced with %s in mempool",
                    $mempool[$i]->upgrade_level, $upgrade_level, $mempool[$i]->hash_str, $new_tx->hash_str);
                $mempool[$i] = $new_tx;
            }
            my $key = $coinbase->btc_tx_hash . $coinbase->btc_out_num;
            if (exists $spent{$key}) {
                # Spent in previous mempool transaction
                $mempool[$i] = undef;
                next;
            }
            $spent{$key} = 1;
        }
        my $skip = 0;
        foreach my $in (@{$mempool[$i]->in}) {
            my $txo = $in->{txo};
            if ($txo->tx_out) {
                # Already confirmed spent (MB not dropped from mempool b/c it was included in some other block in alternate branch)
                $skip = 1;
                last;
            }
            if (exists $spent{$txo->tx_in . $txo->num}) {
                # Spent in previous mempool transaction
                $skip = 1;
                last;
            }
            # the input must be created in earlier mempool transaction or confirmed in the best branch
            # TODO: build transaction dependencies and process mempool tx-chains as single transaction-group with cululative size and fee
            # i.e. if A depends on B then in sort mempool assume weight for A as (A+B); then if include A then include "B;A" (and skip B)
            if (!exists $mempool_out{$txo->tx_in}) {
                # If the transaction is not cached then it's already stored onto database, so it is in the best branch or dropped
                if (my $tx_in = QBitcoin::Transaction->get($txo->tx_in)) {
                    if (!defined($tx_in->block_height)) {
                        $skip = 1;
                        last;
                    }
                    if ($tx_in->block_height >= $block_height) {
                        # confirmed in block that will be rolled back
                        $skip = 1;
                        last;
                    }
                }
                elsif (!QBitcoin::Transaction->get($mempool[$i]->hash)) {
                    # dropped as dependent on $txo->tx_in
                    $skip = 1;
                    last;
                }
            }
            # otherwise it's suitable transaction
        }
        if ($skip) {
            $mempool[$i] = undef;
            next;
        }
        foreach my $in (@{$mempool[$i]->in}) {
            $spent{$in->{txo}->tx_in . $in->{txo}->num} = 1;
        }
        $mempool_out{$mempool[$i]->hash} = scalar @{$mempool[$i]->out};
        $size += $mempool[$i]->size;
        my $low_fee_tx = 0;
        if (!$mempool[$i]->is_coinbase) {
            my $min_fee = min_fee($prev_block, $size);
            # Calculate low-fee transactions in the block with this size and min_fee
            for (my $j = $i; $j >= 0; $j--) {
                defined($mempool[$j]) or next;
                $mempool[$j]->is_standard or last;
                # Avoid compare floating numbers
                if ($mempool[$j]->fee * 1024 < $min_fee * $mempool[$j]->size) {
                    last if ++$low_fee_tx > MAX_EMPTY_TX_IN_BLOCK;
                }
                else {
                    last;
                }
            }
        }
        $tx_in_block++;
        if ($low_fee_tx > MAX_EMPTY_TX_IN_BLOCK || $size > MAX_BLOCK_SIZE || $tx_in_block > MAX_TX_IN_BLOCK) {
            @mempool = splice(@mempool, 0, $i);
            last;
        }
    }
    return grep { defined } @mempool;
}

sub compare_tx {
    # coinbase first
    return
        ( $a->coins_created ? 0 : 1 ) <=> ( $b->coins_created ? 0 : 1 ) || # coinbase first
        $b->fee * $a->size <=> $a->fee * $b->size ||
        $a->received_time  <=> $b->received_time  ||
        $a->hash cmp $b->hash;
}

1;
