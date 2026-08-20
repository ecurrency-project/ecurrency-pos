package QBitcoin::Mempool;
use warnings;
use strict;

# TODO: get transaction weight as fee*age, where age is (time() - $tx->received_time + NN), NN is ~ 10*BLOCK_INTERVAL
# Old transactions will have preferences, and all transactions will be confirmed at one time
# This allow to avoid drop old transactions from the tail of mempool queue
# but transactions with high fee will be confirmed immediately

use QBitcoin::Const;
use QBitcoin::BlockchainParams;
use QBitcoin::Log;
use QBitcoin::ValueUpgraded qw(level_by_total);
use QBitcoin::MinFee qw(min_fee);
use QBitcoin::Transaction;

use constant {
    MAX_PACKAGE_TX       => 64,  # max txs in a package (tx + its unconfirmed ancestors)
    MAX_PACKAGE_FAILURES => 200, # stop selection after this many consecutive unfit packages
};

# Ancestor-package selection (like bitcoin-core BlockAssembler):
# each mempool transaction is a candidate scored by its package - the transaction
# plus all its not-yet-included mempool ancestors, cumulative fee / cumulative size.
# The best-scored package is included as a whole, ancestors before descendants,
# then packages of remaining descendants are rescored without the included part.
# This makes a child spendable in the same block as its unconfirmed parent and
# implements CPFP: an expensive child raises the score of its cheap ancestors.
sub choose_for_block {
    my $class = shift;
    my ($size, $block_time, $prev_block, $can_consume, $branch_only) = @_;
    my $block_height = $prev_block ? $prev_block->height+1 : 0;
    my $upgraded_total = $prev_block ? $prev_block->upgraded : 0;
    # $branch_only: take transactions only from the branch on top of $prev_block, not from
    # the mempool. Used when contesting a block in a past slot, so the mempool stays free
    # for the block in the current timeslot built on top (see QBitcoin::Generate).
    my @mempool;
    if (!$branch_only) {
        @mempool =
            grep { defined($_->min_tx_block_height) && $_->min_tx_block_height <= $block_height &&
                   defined($_->min_tx_time) && $_->min_tx_time <= $block_time }
                QBitcoin::Transaction->mempool_list();
        Debugf("Mempool: %s", join(',', map { $_->hash_str } @mempool)) if @mempool;
    }
    if ($block_height) {
        for (my $block = $prev_block->next_block; $block; $block = $block->next_block) {
            push @mempool, grep { $_->fee >= 0 } @{$block->transactions};
        }
    }
    if ($block_time < SIGN_TOKEN_HASH_START) {
        @mempool = grep { !$_->is_tokens || !$_->token_hash ||  $_->legacy_signature } @mempool;
    }
    else {
        @mempool = grep { !$_->is_tokens || !$_->token_hash || !$_->legacy_signature } @mempool;
    }
    return () unless @mempool;
    if (!$can_consume) {
        @mempool = grep { $_->fee == 0 || $_->coins_created } @mempool;
    }

    my $tx_in_block = $size ? 1 : 0;
    # It's not possible that input was spent in stake transaction
    # b/c we do not use inputs existing in any mempool transaction for stake tx
    my %spent;    # outputs consumed by selected transactions, by txo->key
    my %in_block; # hashes of selected transactions
    my @selected;

    # Coinbase and slashing transactions go first: the block layout enforced by
    # Block::Validate (stake, coinbase(s), slashing(s), standard); they are also
    # exempt from the min_fee limit there.
    my @front    = sort { compare_tx() } grep {   $_->coins_created || $_->is_slashing  } @mempool;
    my @standard =                       grep { !($_->coins_created || $_->is_slashing) } @mempool;

    foreach my $tx (@front) {
        if ($size + $tx->size > MAX_BLOCK_SIZE || $tx_in_block + 1 > MAX_TX_IN_BLOCK) {
            return @selected; # block is full
        }
        if (UPGRADE_POW && $tx->is_coinbase) {
            next if $upgraded_total >= UPGRADE_MAX_VALUE;
            my $coinbase = $tx->up;
            if ($coinbase->tx_out && $coinbase->tx_out ne $tx->hash) {
                # Already confirmed spent with another upgrade level
                Debugf("Coinbase tx %s already spent in confirmed tx %s",
                    $tx->hash_str, $coinbase->tx_out_str);
                next;
            }
            my $upgrade_level = level_by_total($upgraded_total += $coinbase->value_btc);
            if ($tx->upgrade_level != $upgrade_level) {
                # Re-create coinbase transaction with new upgrade level
                my $new_tx = QBitcoin::Transaction->new_coinbase($coinbase, $upgrade_level);
                Debugf("Upgrade level changed %u -> %u, coinbase tx %s replaced with %s in mempool",
                    $tx->upgrade_level, $upgrade_level, $tx->hash_str, $new_tx->hash_str);
                $tx = $new_tx;
            }
            # pack() the number parts of %spent keys: string concatenation of an
            # lvalue-accessor return would set the string flag on the object's own
            # field and JSON encoders would then render it as a string
            my $key = $coinbase->btc_tx_hash . pack("S", $coinbase->btc_out_num);
            next if exists $spent{$key}; # spent in previous mempool transaction
            $spent{$key} = 1;
        }
        next if _obstructed($tx, $block_height, \%spent, \%in_block);
        foreach my $in (@{$tx->in}) {
            $spent{$in->{txo}->key} = 1;
        }
        $in_block{$tx->hash} = 1;
        push @selected, $tx;
        $size += $tx->size;
        $tx_in_block++;
    }

    return @selected unless @standard;

    # Build the dependency graph over the candidates
    my %cand = map { $_->hash => $_ } @standard;
    my %children; # candidate hash -> [ hashes of candidates spending its outputs ]
    my %dead;     # candidate hash -> 1: can not be included in this block
    CAND: foreach my $tx (@standard) {
        foreach my $in (@{$tx->in}) {
            my $txo = $in->{txo};
            if ($txo->tx_out && $txo->tx_out ne $tx->hash) {
                # Already confirmed spent
                $dead{$tx->hash} = 1;
                next CAND;
            }
            my $ph = $txo->tx_in;
            if ($cand{$ph}) {
                push @{$children{$ph}}, $tx->hash;
                next;
            }
            next if $in_block{$ph}; # created by a selected coinbase/slashing transaction
            # the input must be confirmed in the best branch below the new block
            if (my $tx_in = QBitcoin::Transaction->get($ph)) {
                if (!defined($tx_in->block_height) || $tx_in->block_height >= $block_height) {
                    # unconfirmed and not a candidate (excluded or filtered out),
                    # or confirmed in a block that will be rolled back
                    $dead{$tx->hash} = 1;
                    next CAND;
                }
            }
            elsif (!QBitcoin::Transaction->get($tx->hash)) {
                # dropped as dependent on $ph
                $dead{$tx->hash} = 1;
                next CAND;
            }
            # otherwise the input is stored in the database, so confirmed in the best branch
        }
    }

    my %pkg;    # candidate hash -> { order => [ member hashes, ancestors first ], fee, size }
    my %capped; # candidate hash -> 1: too many unconfirmed ancestors; retried after some are included
    my $build_pkg = sub {
        my ($hash) = @_;
        my %ctx = ( seen => {}, pkg_spent => {}, order => [], fee => 0, size => 0 );
        if (_pkg_dfs($hash, \%ctx, \%cand, \%in_block, \%dead, \%spent, 0)) {
            delete $capped{$hash};
            $pkg{$hash} = { order => $ctx{order}, fee => $ctx{fee}, size => $ctx{size} };
            return 1;
        }
        delete $pkg{$hash};
        if ($ctx{capped}) {
            $capped{$hash} = 1;
        }
        else {
            $dead{$hash} = 1;
        }
        return 0;
    };
    foreach my $tx (@standard) {
        next if $dead{$tx->hash};
        $build_pkg->($tx->hash);
    }
    # Static order by initial package score; candidates rescored later go to %modified
    my @queue = sort { _cmp_pkg($pkg{$a->hash}, $a, $pkg{$b->hash}, $b) }
                grep { $pkg{$_->hash} } @standard;
    my $cursor = 0;
    my %modified; # candidate hash -> 1: %pkg entry was rebuilt, position in @queue is stale
    my %failed;   # candidate hash -> 1: package did not fit; cleared if the package shrinks
    my $failures = 0;
    my @included_rates;    # sorted int(fee*1024/size) of selected standard txs with fee > 0
    my $included_zero_fee = 0;

    SELECT: while (1) {
        while ($cursor <= $#queue) {
            my $h = $queue[$cursor]->hash;
            last if !$in_block{$h} && !$modified{$h} && !$failed{$h} && $pkg{$h};
            $cursor++;
        }
        my $best;
        foreach my $h (keys %modified) {
            if ($in_block{$h} || $failed{$h} || !$pkg{$h}) {
                delete $modified{$h};
                next;
            }
            $best = $h if !defined($best) || _cmp_pkg($pkg{$h}, $cand{$h}, $pkg{$best}, $cand{$best}) < 0;
        }
        if ($cursor <= $#queue) {
            my $h = $queue[$cursor]->hash;
            $best = $h if !defined($best) || _cmp_pkg($pkg{$h}, $cand{$h}, $pkg{$best}, $cand{$best}) < 0;
        }
        last unless defined $best;

        # Rebuild: %spent and %dead may have grown since this package was scored
        $build_pkg->($best)
            or next;
        my $p = $pkg{$best};
        if ($tx_in_block + @{$p->{order}} > MAX_TX_IN_BLOCK || $size + $p->{size} > MAX_BLOCK_SIZE) {
            $failed{$best} = 1;
            last if ++$failures >= MAX_PACKAGE_FAILURES;
            next;
        }
        # The block may contain at most MAX_EMPTY_TX_IN_BLOCK transactions below min_fee
        # (consensus, see Block::Validate); min_fee depends on the final block size, so
        # previously included transactions may fall below it as the block grows
        my $new_min_fee = min_fee($prev_block, $size + $p->{size});
        my $low_fee_tx = $included_zero_fee + _count_below(\@included_rates, $new_min_fee);
        foreach my $tx (map { $cand{$_} } @{$p->{order}}) {
            # Avoid compare floating numbers
            $low_fee_tx++ if $tx->fee == 0 || $tx->fee * 1024 < $new_min_fee * $tx->size;
        }
        if ($low_fee_tx > MAX_EMPTY_TX_IN_BLOCK) {
            my $cur_min_fee = min_fee($prev_block, $size);
            if ($p->{fee} * 1024 < $cur_min_fee * $p->{size} &&
                $included_zero_fee + _count_below(\@included_rates, $cur_min_fee) >= MAX_EMPTY_TX_IN_BLOCK) {
                # No remaining package has feerate above this one, so all are below min_fee
                # and need a low-fee slot; the quota is exhausted and min_fee only grows
                last;
            }
            $failed{$best} = 1;
            last if ++$failures >= MAX_PACKAGE_FAILURES;
            next;
        }
        Debugf("Mempool package for %s: %u txs, fee %li, size %u",
            $cand{$best}->hash_str, scalar(@{$p->{order}}), $p->{fee}, $p->{size}) if @{$p->{order}} > 1;
        foreach my $h (@{$p->{order}}) {
            my $tx = $cand{$h};
            push @selected, $tx;
            $in_block{$h} = 1;
            foreach my $in (@{$tx->in}) {
                $spent{$in->{txo}->key} = 1;
            }
            $size += $tx->size;
            $tx_in_block++;
            if ($tx->fee == 0) {
                $included_zero_fee++;
            }
            else {
                _insert_rate(\@included_rates, int($tx->fee * 1024 / $tx->size));
            }
        }
        $failures = 0;
        # Rescore descendants: their remaining (not included) package part changed
        my %touch;
        foreach my $h (@{$p->{order}}) {
            _collect_descendants($h, \%children, \%touch);
        }
        foreach my $h (keys %touch) {
            next if $in_block{$h} || $dead{$h};
            delete $failed{$h}; # the package shrank, it may fit now
            $modified{$h} = 1 if $build_pkg->($h);
        }
    }
    return @selected;
}

# Check inputs of a coinbase/slashing transaction against the current block state
sub _obstructed {
    my ($tx, $block_height, $spent, $in_block) = @_;
    foreach my $in (@{$tx->in}) {
        my $txo = $in->{txo};
        return 1 if $txo->tx_out && $txo->tx_out ne $tx->hash; # already confirmed spent
        return 1 if exists $spent->{$txo->key};                # spent in previous mempool transaction
        my $ph = $txo->tx_in;
        next if $in_block->{$ph};
        if (my $tx_in = QBitcoin::Transaction->get($ph)) {
            return 1 if !defined($tx_in->block_height) || $tx_in->block_height >= $block_height;
        }
        elsif (!QBitcoin::Transaction->get($tx->hash)) {
            return 1; # dropped as dependent on $ph
        }
    }
    return 0;
}

# Depth-first walk over not-yet-included mempool ancestors; emits parents before
# children into $ctx->{order} and sums package fee and size.
# Returns false if the package is unusable: $ctx->{capped} is set if it exceeds
# MAX_PACKAGE_TX (may shrink after some ancestors are included), otherwise the
# package contains a conflict or a dead ancestor and the root is dead for good.
sub _pkg_dfs {
    my ($hash, $ctx, $cand, $in_block, $dead, $spent, $depth) = @_;
    return 1 if $ctx->{seen}{$hash}++;
    return 1 if $in_block->{$hash};
    if ($depth > MAX_PACKAGE_TX) {
        $ctx->{capped} = 1;
        return 0;
    }
    my $tx = $cand->{$hash}
        or return 1; # not a candidate: input checked on the graph build, confirmed in the best branch
    return 0 if $dead->{$hash};
    foreach my $in (@{$tx->in}) {
        my $txo = $in->{txo};
        my $key = $txo->key;
        if (exists $spent->{$key}) {
            # conflicts with an already selected transaction, never includable
            $dead->{$hash} = 1;
            return 0;
        }
        if ($ctx->{pkg_spent}{$key}++) {
            # two members of the package spend the same output; the root needs both,
            # so it is dead, but each member may be valid in another package
            return 0;
        }
        _pkg_dfs($txo->tx_in, $ctx, $cand, $in_block, $dead, $spent, $depth + 1)
            or return 0;
    }
    push @{$ctx->{order}}, $hash;
    $ctx->{fee}  += $tx->fee;
    $ctx->{size} += $tx->size;
    if (@{$ctx->{order}} > MAX_PACKAGE_TX) {
        $ctx->{capped} = 1;
        return 0;
    }
    return 1;
}

# Package feerate descending (compare without division), then oldest first for determinism
sub _cmp_pkg {
    my ($pa, $ta, $pb, $tb) = @_;
    return
        $pb->{fee} * $pa->{size} <=> $pa->{fee} * $pb->{size} ||
        ($ta->received_time // 0) <=> ($tb->received_time // 0) ||
        $ta->hash cmp $tb->hash;
}

sub _collect_descendants {
    my ($hash, $children, $touch) = @_;
    my @stack = @{$children->{$hash} // []};
    while (defined(my $h = pop @stack)) {
        next if $touch->{$h}++;
        push @stack, @{$children->{$h} // []};
    }
}

# $rates is sorted ascending; count entries below $min_fee
sub _count_below {
    my ($rates, $min_fee) = @_;
    my ($lo, $hi) = (0, scalar @$rates);
    while ($lo < $hi) {
        my $mid = ($lo + $hi) >> 1;
        $rates->[$mid] < $min_fee ? ($lo = $mid + 1) : ($hi = $mid);
    }
    return $lo;
}

sub _insert_rate {
    my ($rates, $rate) = @_;
    splice(@$rates, _count_below($rates, $rate + 1), 0, $rate);
}

sub compare_tx {
    # coinbase first, then slashing, then standard: the block layout enforced by
    # Block::Validate (stake, coinbase(s), slashing(s), standard)
    return
        ( $a->coins_created ? 0 : $a->is_slashing ? 1 : 2 ) <=> ( $b->coins_created ? 0 : $b->is_slashing ? 1 : 2 ) ||
        ( $a->up && $b->up ? (
            ($a->up->btc_block_height // 0) <=> ($b->up->btc_block_height // 0) ||
            ($a->up->btc_tx_num       // 0) <=> ($b->up->btc_tx_num       // 0) ||
            ($a->up->btc_out_num      // 0) <=> ($b->up->btc_out_num      // 0)
        ) : 0 ) ||
        $b->fee * $a->size <=> $a->fee * $b->size ||
        ($a->received_time // 0) <=> ($b->received_time // 0) ||
        $a->hash cmp $b->hash;
}

1;
