package QBitcoin::Block::Receive;
use warnings;
use strict;

use Scalar::Util qw(refaddr);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::TXO;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced skip_scripts);
use QBitcoin::CheckPoints qw(checkpoint_hash max_checkpoint_height prev_checkpoint_height);
use QBitcoin::Transaction;
use QBitcoin::ConnectionList;
use QBitcoin::Generate::Control;
use QBitcoin::Notify;
use QBitcoin::Peer;
use Role::Tiny; # This is role for QBitcoin::Block;

# @block_pool - array (by height) of hashes, block by block->hash
# @best_block - pointers to blocks in the main branch
# %descendant - list of block descendants (including pending), as $descendant{$prev_hash}->{$hash}

# Each block has attributes:
# - self_weight - weight calculated by the block contents
# - weight - weight of the branch ended with this block, i.e. self_weight of the block and all its ancestors

# We ignore blocks from peer which has weight less than our best branch
# Last INCORE_LEVELS levels keep in memory, and only then save to the database
# If we receive block with good weight (better than out best) but with unknown ancestor then
# request the ancestor and do not switch the best branch until we have completely linked branch and verify its weight

my @block_pool;
my %block_pool;
my @best_block;
my %descendant;
my $HEIGHT;
my $MIN_INCORE_HEIGHT;
my $best_is_generated = 0;

END {
    # free structures
    undef @best_block;
    undef %descendant;
    undef @block_pool;
};

sub best_weight {
    return defined($HEIGHT) ? $best_block[$HEIGHT]->weight : -1;
}

sub blockchain_height {
    return $HEIGHT;
}

sub blockchain_time {
    return defined($HEIGHT) ? timeslot($best_block[$HEIGHT]->time) : 0;
}

sub best_block {
    my $class = shift;
    my ($block_height) = @_;
    $block_height //= $HEIGHT;
    return defined($block_height) ? $best_block[$block_height] : undef;
}

sub best_is_generated {
    return $best_is_generated;
}

sub min_incore_height {
    return $MIN_INCORE_HEIGHT;
}

sub max_incore_height {
    return $#block_pool;
}

sub to_cache {
    my $self = shift;
    $block_pool[$self->height]->{$self->hash} = $self;
    $block_pool{$self->hash} = $self;
    $self->add_as_descendant();
    $MIN_INCORE_HEIGHT = $self->height if !defined($MIN_INCORE_HEIGHT) || $MIN_INCORE_HEIGHT > $self->height;
}

sub is_cached {
    my $self = shift;
    return exists($block_pool{$self->hash}) && refaddr($block_pool{$self->hash}) == refaddr($self);
}

sub add_as_descendant {
    my $self = shift;
    $descendant{$self->prev_hash}->{$self->hash} = $self if $self->prev_hash;
}

sub del_as_descendant {
    my $self = shift;
    if ($self->prev_hash) {
        delete $descendant{$self->prev_hash}->{$self->hash};
        delete $descendant{$self->prev_hash} unless %{$descendant{$self->prev_hash}};
    }
}

sub descendants {
    my $self = shift;
    return $descendant{$self->hash} ? values %{$descendant{$self->hash}} : ();
}

sub block_pool {
    my $class = shift;
    my ($hash) = @_;
    return $block_pool{$hash};
}

sub receive {
    my $self = shift;
    my ($loaded) = @_;

    return 0 if $block_pool{$self->hash};
    # $self->prev_block must be already loaded by prev_block_load in QBitcoin::Protocol
    skip_scripts($self->height <= max_checkpoint_height() ? 1 : 0);
    if (my $err = $self->validate()) {
        Warningf("Incorrect block %s from %s: %s", $self->hash_str, $self->received_from ? $self->received_from->peer->id : "me", $err);
        # Incorrect block
        # NB! Incorrect hash is not this case, hash must be checked earlier
        # Drop descendants, it's not possible to receive correct block with the same hash
        $self->free();
        if ($self->received_from) {
            if ($self->received_from->connection) {
                $self->received_from->abort("invalid_block");
            }
        }
        # If this block failed checkpoint validation, the chain since the previous checkpoint
        # is from a malicious peer (scripts were skipped during IBD). Roll back to allow
        # re-syncing from an honest peer.
        if (checkpoint_hash($self->height)) {
            _rollback_to_checkpoint($self->height);
            # Ban the offending peer so it is not selected as sync peer again.
            # decrease_reputation() with -MIN_REPUTATION ensures the peer drops
            # below the ban threshold regardless of its current score.
            if ($self->received_from) {
                Warningf("Banning peer %s due to checkpoint hash mismatch", $self->received_from->peer->id);
                $self->received_from->peer->decrease_reputation(-QBitcoin::Peer::MIN_REPUTATION);
                if ($self->received_from->connection) {
                    $self->received_from->connection->disconnect();
                }
            }
        }
        return -1;
    }

    $self->to_cache;
    if ($self->prev_block) {
        $self->prev_block->next_block //= $self;
    }

    # zero weight for the new block is ok, accept it
    if ($HEIGHT && ($self->weight < $best_block[$HEIGHT]->weight ||
        ($self->weight == $best_block[$HEIGHT]->weight && $self->branch_height <= $HEIGHT))) {
        my $has_weight = $self->received_from ? ($self->received_from->has_weight // -1) : -1;
        Debugf("Received block %s height %u from %s has too low weight for us: %Lu <= %Lu",
            $self->hash_str, $self->height, $self->received_from ? $self->received_from->peer->id : "me",
            $self->weight, $best_block[$HEIGHT]->weight);
        return 0;
    }

    # We have candidate for the new best branch, validate it
    # Find first common block between current best branch and the candidate
    my $class = ref $self;
    my $new_best;
    for ($new_best = $self; $new_best->height > 0; $new_best = $new_best->prev_block) {
        # "root" best_block for this new branch must be already loaded
        my $best_block = $class->best_block($new_best->height-1);
        last if $best_block && $best_block->hash eq $new_best->prev_hash;
        $new_best->prev_block->next_block = $new_best;
    }
    if (defined($HEIGHT) && $new_best->height == 0) {
        die "Error receiving alternative branch";
    }
    # $new_best is first block in new branch after fork, i.e $new_nest->prev_block is in the current best branch
    if ($new_best->height < ($HEIGHT // -1)) {
        if ($new_best->height <= max_checkpoint_height()) {
            Debugf("Reject reorg: fork at height %u is at or below checkpoint %u",
                $new_best->height - 1, max_checkpoint_height());
            return 0;
        }
        if ($best_block[$HEIGHT]->weight + $best_block[$HEIGHT]->reorg_penalty($new_best->prev_block) >= $self->weight) {
            Debugf("Alternate branch has weight %Lu more than current %Lu but prevent switching because of reorg penalty for %u levels", $self->weight, $best_block[$HEIGHT]->weight, $HEIGHT - $new_best->height + 1);
            return 0;
        }
        Infof("Check alternate branch started with block %s height %u with weight %Lu (current best weight %Lu)",
            $new_best->hash_str, $new_best->height, $self->weight, $self->best_weight);
    }

    # reset all txo in the current best branch (started from the fork block) as unspent;
    # then set output in all txo in the new branch and check it against possible double-spend
    for (my $bl = $class->best_block($HEIGHT // $new_best->height); $bl && $bl->height >= $new_best->height; $bl = $bl->prev_block_load) {
        $bl->prev_block_load->next_block = $bl;
        Debugf("Remove block %s height %u from the best branch", $bl->hash_str, $bl->height);
        foreach my $tx (reverse @{$bl->transactions}) {
            $tx->unconfirm();
        }
    }
    my $old_best = $class->best_block($new_best->height);
    for (my $bl = $new_best; $bl; $bl = $bl->next_block) {
        Debugf("Add block %s height %u to the best branch", $bl->hash_str, $bl->height);
        my $fail_tx = $bl->validate_chain();

        if ($fail_tx) {
            Debugf("Revert block %s height %u from best branch", $bl->hash_str, $bl->height);
            for (my $bl1 = $bl->prev_block; $bl1 && $bl1->height >= $new_best->height; $bl1 = $bl1->prev_block) {
                Debugf("Revert block %s height %u from the best branch", $bl1->hash_str, $bl1->height);
                foreach my $tx (reverse @{$bl1->transactions}) {
                    $tx->unconfirm();
                }
            }

            $old_best->prev_block->next_block = $old_best if $old_best && $old_best->prev_block;
            for (my $bl1 = $old_best; $bl1; $bl1 = $bl1->next_block) {
                Debugf("Return block %s height %u to the best branch", $bl1->hash_str, $bl1->height);
                my $num = 0;
                foreach my $tx (@{$bl1->transactions}) {
                    $tx->confirm($bl1, $num++);
                }
            }
            $bl->drop_branch();
            if ($self->received_from) {
                if ($self->received_from->connection) {
                    $self->received_from->abort("incorrect_block");
                }
            }
            return -1;
        }
    }

    # set best branch
    $new_best->prev_block->next_block = $new_best if $new_best->prev_block;
    if ($new_best->height <= QBitcoin::Block->max_db_height && !$loaded) {
        # Remove stored blocks in old best branch to keep database blockchain consistent during saving new branch
        # and do not create huge sql transactions
        QBitcoin::Block->delete_by(height => { '>=' => $new_best->height });
        QBitcoin::Block->max_db_height($new_best->height-1);
    }
    for (my $bl = $new_best; $bl; $bl = $bl->next_block) {
        $best_block[$bl->height] = $bl;
    }

    # Notify about confirmed transactions to tracked addresses
    if (!$loaded && blockchain_synced() && QBitcoin::Notify->enabled()) {
        for (my $bl = $new_best; $bl; $bl = $bl->next_block) {
            QBitcoin::Notify->check_block($bl);
        }
    }

    if ($self->received_from && $self->self_weight) {
        $self->received_from->peer->add_reputation(blockchain_synced() ? 2 : 0.02);
        if ($self->rcvd && $self->rcvd ne $self->received_from->peer->ip && $self->rcvd ne "\x00"x16) {
            my $src_peer = QBitcoin::Peer->get_or_create(type_id => PROTOCOL_QBITCOIN, ip => $self->rcvd);
            $src_peer->add_reputation(blockchain_synced() ? 1 : 0.01) if $src_peer;
        }
    }

    if (defined($HEIGHT) && $new_best->height <= $HEIGHT) {
        Debugf("%s block height %u hash %s, best branch altered, weight %Lu, %u transactions",
            $self->received_from ? "received" : "loaded", $self->height,
            $self->hash_str, $self->weight, scalar(@{$self->transactions}));
    }
    else {
        Debugf("%s block height %u hash %s in the best branch, weight %Lu, %u transactions",
            $self->received_from ? "received" : "loaded", $self->height,
            $self->hash_str, $self->weight, scalar(@{$self->transactions}));
    }

    if (blockchain_synced()) {
        my $timeslot = timeslot(time());
        if ($timeslot > timeslot($new_best->time)) {
            QBitcoin::Generate::Control->generate_new();
        }
        if ($self->received_from || timeslot($self->time) >= $timeslot) {
            # Do not announce old blocks loaded from the local database or generated
            $self->announce_to_peers();
        }
        # This flag is used for regenerate block on receive new transaction
        $best_is_generated = $self->received_from ? 0 : 1;
    }

    my $old_height = $HEIGHT;
    if (defined($HEIGHT) && $self->height < $HEIGHT) {
        foreach my $n ($self->height+1 .. $HEIGHT) {
            delete $best_block[$n];
        }
        $HEIGHT = $self->height;
    }

    if ($old_best) {
        # Drop old branch to free my txo for possibility to make new stake transactions
        # Drop if the old branch has the same or less height than the new best branch
        # or if it contains my stake transactions
        # Otherwise it's possible to receive new block with the old branch and it will become the best again
        my $self_branch = 0;
        if ($old_height < $self->height) {
            for (my $bl = $old_best; $bl; $bl = $bl->next_block) {
                if (!$bl->received_from && $bl->transactions && $bl->transactions->[0]->is_stake) {
                    $self_branch = 1;
                    last;
                }
            }
        }
        if ($old_height >= $self->height || $self_branch) {
            $old_best->drop_branch();
        }
    }

    if ($self->height > ($HEIGHT // -1)) {
        # It's the first block in this level
        # Store and free old level (if it's in the best branch)
        $HEIGHT = $self->height;
        if ($HEIGHT >= INCORE_LEVELS) {
            my $class = ref($self);
            $class->cleanup_old_blocks();
        }
    }

    # Remove transactions with spent inputs from the mempool
    # Do it only when we got new best block
    # b/c the best chain may has several transactions with inputs spent in our chain,
    # and we should not cleanup mempool after receive each of these transactions
    if (mempool_synced() && blockchain_synced()) {
        QBitcoin::Transaction->cleanup_mempool();
    }

    return 0;
}

sub _rollback_to_checkpoint {
    my ($failed_height) = @_;

    my $target_height = prev_checkpoint_height($failed_height);
    Warningf("Rolling back blockchain from height %u to %d to recover from checkpoint failure",
        $HEIGHT // -1, $target_height);

    # Unconfirm and free in-memory blocks (those not yet stored to DB)
    while (defined($HEIGHT) && $HEIGHT > $target_height) {
        my $h = $HEIGHT;
        if (my $bl = delete $best_block[$h]) {
            foreach my $tx (reverse @{$bl->transactions}) {
                $tx->unconfirm();
            }
            $bl->free();
        }
        $HEIGHT--;
    }
    $HEIGHT = undef if defined($HEIGHT) && $HEIGHT < 0;

    # Clear next_block pointer on new best tip
    if (defined($HEIGHT) && $best_block[$HEIGHT]) {
        $best_block[$HEIGHT]->next_block(undef);
    }

    # Handle blocks already stored to DB
    my $class = 'QBitcoin::Block';
    if ($class->max_db_height > $target_height) {
        my $tx_class = 'QBitcoin::Transaction';
        # Load and unconfirm transactions from stored blocks to restore UTXO state
        foreach my $tx_hashref ($tx_class->fetch(
            block_height => { '>', $target_height },
            -sortby => 'block_height DESC, block_pos DESC'))
        {
            my $tx = $tx_class->get($tx_hashref->{hash});
            if (!$tx) {
                $tx_class->pre_load($tx_hashref);
                $tx = $tx_class->new($tx_hashref);
                if ($tx->validate_hash) {
                    foreach my $in (@{$tx->in}) {
                        $in->{txo}->spent_del($tx);
                    }
                    next;
                }
                $tx->add_to_cache;
            }
            $tx->unconfirm();
        }
        # Delete blocks from DB in one query (cascades to transactions)
        $class->delete_by(height => { '>' => $target_height });
        $class->max_db_height($target_height);
    }

    $MIN_INCORE_HEIGHT = undef if defined($MIN_INCORE_HEIGHT) && $MIN_INCORE_HEIGHT > $target_height + 1;
}

sub store_blocks {
    my $class = shift;
    defined($HEIGHT) or return;
    my $time = time();
    for (my $level = QBitcoin::Block->max_db_height + 1; $level <= $HEIGHT; $level++) {
        if ($time - $best_block[$level]->time >= INCORE_TIME) {
            $best_block[$level]->store();
        }
    }
}

sub want_cleanup_branch {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my ($block) = @_;
    while (1) {
        return 0 if $block->received_from && $block->received_from->syncing
            && ($block->received_from->has_weight // -1) > QBitcoin::Block->best_weight;
        return 0 if $block->height > ($HEIGHT // -1) - INCORE_LEVELS;
        my @descendants = $block->descendants;
        # avoid too deep recursion
        my $next_block = pop @descendants
            or last;
        foreach my $descendant (@descendants) {
            if (want_cleanup_branch($descendant)) {
                drop_branch($descendant);
            }
            else {
                return 0;
            }
        }
        $block = $next_block;
    }
    return 1;
}

sub cleanup_old_blocks {
    my $class = shift;
    my $first_free_height = ($HEIGHT // -1) - INCORE_LEVELS;
    my $max_db_height = $class->max_db_height;
    $first_free_height = $max_db_height if $first_free_height > $max_db_height;
    for (my $free_height = $MIN_INCORE_HEIGHT // -1; $free_height <= $first_free_height; $free_height++) {
        if ($free_height < $first_free_height) {
            foreach my $bl (values %{$block_pool[$free_height+1]}) {
                next if $best_block[$free_height+1] && $bl->hash eq $best_block[$free_height+1]->hash; # cleanup best branch after all other
                # cleanup only full branches; if prev_block has single descendant then this branch was already checked
                if ($bl->prev_block && scalar($bl->prev_block->descendants) == 1) {
                    if (!$best_block[$free_height] || $bl->prev_block->hash ne $best_block[$free_height]->hash) {
                        next;
                    }
                }
                drop_branch($bl) if want_cleanup_branch($bl);
            }
        }
        last if keys(%{$block_pool[$free_height]}) > 1;
        if ($best_block[$free_height]) {
            foreach my $descendant (grep { $_->is_pending } $best_block[$free_height]->descendants) {
                $descendant->drop_pending();
            }
            my @descendants = $best_block[$free_height]->descendants;
            if (@descendants > 1 || (@descendants == 1 && !$best_block[$free_height+1])) {
                last;
            }
            # we have only best block on this level without descendants in alternate branches, drop it and cleanup the level
            $best_block[$free_height]->free();
            foreach my $descendant (@descendants) {
                $descendant->prev_block(undef);
            }
            delete $best_block[$free_height];
        }
        elsif (%{$block_pool[$free_height]}) {
            last;
        }
        delete $block_pool[$free_height];
        Debugf("Level %u cleared", $free_height);
        $MIN_INCORE_HEIGHT++;
    }
}

sub free {
    my ($block) = @_;

    Debugf("Free block %s height %u from memory cache", $block->hash_str, $block->height);
    if ($block->prev_block) {
        $block->prev_block->next_block(undef);
        $block->prev_block(undef);
    }
    $block->next_block(undef);
    delete $block_pool[$block->height]->{$block->hash};
    delete $block_pool{$block->hash};
    $block->del_as_descendant();
    $block->free_tx();
    $block->drop_pending();
}

sub drop_branch {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my ($block) = @_;

    # Change recursion to loop for chain with single descendant to avoid too deep recursion for drop long chains
    # Drop starting with leaves (fresh blocks) to root (blocks with lower height)
    # to prevent too long stake transactions dependency and deep recursion during drop dependent transactions
    my $cur_block = $block;
    while (my @descendants = $cur_block->descendants) {
        $cur_block = pop @descendants;
        foreach my $descendant (@descendants) {
            $descendant->drop_branch(); # recursively
        }
    }
    while (1) {
        my $prev_block = $cur_block->prev_block;
        $cur_block->free();
        last if $cur_block->hash eq $block->hash;
        $cur_block = $prev_block;
    }
}

sub prev_block {
    my $self = shift;
    if (@_) {
        if ($_[0]) {
            $_[0]->hash eq $self->prev_hash
                or die "Incorrect block linking";
            $self->{height} //= $_[0]->height + 1;
            return $self->{prev_block} = $_[0];
        }
        else {
            # It's not set "unexising" prev, it's free pointer which will be load again on demand
            delete $self->{prev_block}; # load again on demand
            return undef;
        }
    }
    return $self->{prev_block} if exists $self->{prev_block}; # undef means we have no such block
    return undef unless $self->prev_hash; # genesis block has no ancestors
    if (my $prev_block = $block_pool{$self->prev_hash}) {
        $self->{prev_block} = $prev_block;
        $self->{height} = $prev_block->height + 1;
    }
    return $self->{prev_block};
}

sub prev_block_load {
    my $self = shift;
    return $self->{prev_block} if exists $self->{prev_block}; # undef means we have no such block
    return undef unless $self->prev_hash; # genesis block has no ancestors
    return $self->{prev_block} if $self->prev_block; # exists in block_pool
    my $class = ref($self);
    if (my $prev_block = $class->find(hash => $self->prev_hash)) {
        $prev_block->to_cache;
        $best_block[$prev_block->height] = $prev_block;
        $self->{prev_block} = $prev_block;
        $self->{height} = $prev_block->height + 1;
    }
    return $self->{prev_block};
}

sub announce_to_peers {
    my $self = shift;

    foreach my $connection (QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN)) {
        next if $self->received_from && $connection->peer->id eq $self->received_from->peer->id;
        next unless $connection->protocol->can('announce_block');
        $connection->protocol->announce_block($self);
    }
}

sub unconfirm {
    my $self = shift;

    $self->hash eq $best_block[$HEIGHT]->hash
        or die "Can unconfirm only best block";
    foreach my $tx (reverse @{$self->transactions}) {
        $tx->unconfirm();
    }
    $self->free();
    $HEIGHT--;
}

1;
