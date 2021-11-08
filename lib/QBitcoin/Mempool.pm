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
    return grep { $_->coins_created && defined($_->min_tx_time) && $_->min_tx_time <= $block_time }
        QBitcoin::Transaction->mempool_list();
}

sub choose_for_block {
    my $class = shift;
    my ($size, $block_time) = @_;
    my @mempool = sort { compare_tx($a, $b) }
        grep { defined($_->min_tx_time) && $_->min_tx_time <= $block_time }
            QBitcoin::Transaction->mempool_list()
                or return ();
    Debugf("Mempool: %s", join(',', map { $_->hash_str } @mempool));
    if ($size == 0) {
        # We can include only transactions with zero fee into block without stake transaction
        @mempool = grep { $_->fee == 0 } @mempool;
    }
    my $empty_tx = 0;
    my $tx_in_block = $size ? 1 : 0;
    # It's not possible that input was spent in stake transaction
    # b/c we do not use inputs existing in any mempool transaction for stake tx
    my %spent;
    my %mempool_out; # for allow spend unconfirmed in the same block
    for (my $i=0; $i<=$#mempool; $i++) {
        my $skip = 0;
        foreach my $in (@{$mempool[$i]->in}) {
            my $txo = $in->{txo};
            if ($txo->tx_out) {
                # Already confirmed spent (MB not dropped from mempool b/c it included in some other block in alternate branch)
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
        $empty_tx++ if $mempool[$i]->fee == 0 && @{$mempool[$i]->in};
        $size += $mempool[$i]->size;
        $tx_in_block++;
        if ($empty_tx > MAX_EMPTY_TX_IN_BLOCK || $size > MAX_BLOCK_SIZE - BLOCK_HEADER_SIZE || $tx_in_block >= MAX_TX_IN_BLOCK) {
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
        $b->fee * $a->size    <=> $a->fee * $b->size    ||
        $a->received_time     <=> $b->received_time     ||
        $a->hash cmp $b->hash;
}

1;
