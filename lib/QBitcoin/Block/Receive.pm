package QBitcoin::Block::Receive;
use warnings;
use strict;

use Role::Tiny; # This is role for QBitcoin::Block;
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::TXO;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Peers;
use QBitcoin::Generate::Control;

# @block_pool - array (by height) of hashes, block by block->hash
# @best_block - pointers to blocks in the main branch
# @prev_block - get block by its "prev_block" attribute, split to array by block height, for search block descendants

# Each block has attributes:
# - self_weight - weight calculated by the block contents
# - weight - weight of the branch ended with this block, i.e. self_weight of the block and all its ancestors
# - branch_weight (calculated) - weight of the best branch contains this block, i.e. maximum weight of the block descendants

# We ignore blocks with branch_weight less than our best branch
# Last INCORE_LEVELS levels keep in memory, and only then save to the database
# If we receive block with good branch_weight (better than out best) but with unknown ancestor then
# request the ancestor and do not switch best branch until we have full linked branch and verify its weight

my @block_pool;
my @best_block;
my @prev_block;
my $height;

my $declared_height = 0;

sub best_weight {
    return defined($height) ? $best_block[$height]->weight : -1;
}

sub blockchain_height {
    return $height;
}

sub best_block {
    my $class = shift;
    my ($block_height) = @_;
    return $best_block[$block_height] //
        ($block_height <= ($height // -1) - INCORE_LEVELS ? $class->find(height => $block_height) : undef);
}

sub block_pool {
    my $class = shift;
    my ($block_height, $hash) = @_;
    return $block_pool[$block_height]->{$hash};
}

sub declared_height {
    my $class = shift;
    if (@_) {
        my ($height) = @_;
        $declared_height = $height if $declared_height < $height;
    }
    return $declared_height;
}

sub hash_out {
    my $arg = shift;
    my $hash = ref($arg) ? $arg->hash : $arg;
    # TODO: return full hash
    return unpack("H*", substr($hash, 0, 4));
}

sub receive {
    my $self = shift;

    return 0 if $block_pool[$self->height]->{$self->hash};
    if (my $err = $self->validate()) {
        Warningf("Incorrect block from %s: %s", $self->received_from ? $self->received_from->ip : "me", $err);
        # Incorrect block
        # NB! Incorrect hash is not this case, hash must be checked earlier
        # Drop descendants, it's not possible to receive correct block with the same hash
        if (my $descendants = $prev_block[$self->height+1]->{$self->hash}) {
            foreach my $descendant (values %$descendants) {
                $descendant->drop_branch();
            }
        }
        if ($self->received_from) {
            $self->received_from->decrease_reputation();
            $self->received_from->send_line("abort invalid_block");
        }
        return -1;
    }
    # Do we have a descendant for this block?
    my $new_weight = $self->weight;
    my $descendant;
    if ($prev_block[$self->height+1] && (my $descendants = $prev_block[$self->height+1]->{$self->hash})) {
        foreach my $descendant (values %$descendants) {
            if ($descendant->weight != $self->weight + $descendant->self_weight) {
                Warningf("Incorrect descendant weight %u != %u, drop it", $descendant->weight, $self->weight + $descendant->self_weight);
                $descendant->drop_branch();
            }
            elsif ($new_weight < $descendant->branch_weight) {
                $new_weight = $descendant->branch_weight;
                $self->next_block = $descendant;
            }
        }
    }
    if (COMPACT_MEMORY) {
        if (defined($height) && $best_block[$height] && $new_weight < $best_block[$height]->branch_weight) {
            Debugf("Received branch weight %u not more than our best branch weight %u, ignore",
                $new_weight, $best_block[$height]->branch_weight);
            return 0; # Not needed to drop descendants b/c there were dropped when weight of the current branch become more than their weight
        }
        if ($self->prev_hash && (my $alter_descendants = $prev_block[$self->height]->{$self->prev_hash})) {
            my $best_block_this = $best_block[$self->height];
            foreach my $alter_descendant (values %$alter_descendants) {
                next if $best_block_this && $alter_descendant->hash eq $best_block_this->hash; # Do not drop the best branch here
                if ($alter_descendant->branch_weight > $new_weight) {
                    Debugf("Alternative branch has weight %u more then received one %s, ignore",
                        $alter_descendant->branch_weight, $new_weight);
                    return 0;
                }
                Debugf("Drop alternative branch with weight %u less than new %s",
                    $alter_descendant->branch_weight, $new_weight);
                $alter_descendant->drop_branch();
            }
        }
    }
    if ($height && $self->height < $height && $self->received_from) {
        # Remove blocks received from this peer and not linked with this one
        # The best branch was changed on the peer
        foreach my $b (values %{$block_pool[$self->height+1]}) {
            next if $best_block[$b->height]->hash eq $b->hash;
            next if !$b->received_from;
            next if $b->received_from->ip ne $self->received_from->ip;
            next if $b->prev_hash eq $self->hash;
            Debugf("Remove orphan descendant %s height %u received from this peer %s",
                $b->hash_out, $b->height, $self->received_from->ip);
            $b->drop_branch();
        }
    }

    $block_pool[$self->height]->{$self->hash} = $self;
    $prev_block[$self->height]->{$self->prev_hash}->{$self->hash} = $self if $self->prev_hash;

    if ($self->prev_block) {
        if ($self->weight != $self->prev_block->weight + $self->self_weight) {
            Debugf("Incorrect block %s height %u weight %u!=%u+%u",
                $self->hash_out, $self->height, $self->weight, $self->prev_block->weight, $self->self_weight);
            return 0;
        }
        $self->prev_block->next_block = $self;
    }
    elsif ($self->height) {
        Debugf("No prev block with height %s hash %s, request it", $self->height-1, hash_out($self->prev_hash));
        $self->received_from->send_line("sendblock " . ($self->height-1));
        return 0;
    }
    if (!$self->height || $self->prev_block->linked) {
        if ($self->set_linked() != 0) { # with descendants
            # Invalid branch, dropped
            return 0;
        }
        # zero weight for new block is ok, accept it
        if ($height && ($self->branch_weight < $best_block[$height]->weight ||
            ($self->branch_weight == $best_block[$height]->weight && $self->branch_height <= $height))) {
            Debugf("Received block height %s from %s has too low weight for us, ignore",
                $self->height, $self->received_from ? $self->received_from->ip : "me");
            return 0;
        }

        # We have candidate for the new best branch, validate it
        # Find first common block between current best branch and the candidate
        my $class = ref $self;
        my $new_best;
        for ($new_best = $self; $new_best->prev_block; $new_best = $new_best->prev_block) {
            my $best_block = $class->best_block($new_best->height-1);
            last if !$best_block || $best_block->hash eq $new_best->prev_hash;
            $new_best->prev_block->next_block = $new_best;
        }

        # reset all txo in the current best branch (started from the fork block) as unspent;
        # then set output in all txo in new branch and check it against possible double-spend
        for (my $b = $class->best_block($new_best->height); $b; $b = $b->next_block) {
            foreach my $tx (@{$b->transactions}) {
                $tx->unconfirm();
            }
        }
        for (my $b = $new_best; $b; $b = $b->next_block) {
            foreach my $tx (@{$b->transactions}) {
                $tx->block_height = $b->height;
                foreach my $in (@{$tx->in}) {
                    my $txo = $in->{txo};
                    my $correct = 1;
                    if ($txo->tx_out) {
                        # double-spend; drop this branch, return to old best branch and decrease reputation for peer $b->received_from
                        Warningf("Double spend for transaction output %s:%u: first in transaction %s, second in %s, block from %s",
                            unpack("H*", $txo->tx_in), $in->{txo}->num, unpack("H*", $txo->tx_out), unpack("H*", $tx->hash),
                            $b->received_from ? $b->received_from->ip : "me");
                        $correct = 0;
                    }
                    elsif (my $tx_in = QBitcoin::Transaction->get($txo->tx_in)) {
                        # Transaction with this output must be already confirmed (in the same best branch)
                        # Stored (not cached) transactions are always confirmed, not needed to load them
                        if (!$tx_in->block_height) {
                            Warning("Unconfirmed input %s:%u for transaction %s, block from %s",
                                unpack("H*", $txo->tx_in), $txo->num, unpack("H*", $tx->hash),
                                $b->received_from ? $b->received_from->ip : "me");
                            $correct = 0;
                        }
                    }
                    if ($correct) {
                        $txo->tx_out = $tx->hash;
                        $txo->close_script = $in->{close_script};
                        $txo->del_my_utxo if $txo->is_my;
                    }
                    else {
                        for (my $b1 = $new_best; $b1; $b1 = $b1->next_block) {
                            foreach my $tx1 (@{$b1->transactions}) {
                                $tx1->unconfirm();
                            }
                        }
                        for (my $b1 = $class->best_block($new_best->height); $b1; $b1 = $b1->next_block) {
                            foreach my $tx1 (@{$b1->transactions}) {
                                $tx1->block_height = $b1->height;
                                foreach my $in (@{$tx1->in}) {
                                    my $txo = $in->{txo};
                                    $txo->tx_out = $tx1->hash;
                                    $txo->close_script = $in->{close_script};
                                    $txo->del_my_utxo if $txo->is_my;
                                }
                            }
                        }
                        $b->drop_branch();
                        # $self may be correct block, so we have no reasons for decrease reputation of the current peer
                        # but we can decrease reputation of the peer which sent us block with double-spend transaction
                        $b->received_from->decrease_reputation if $b->received_from;
                        if ($b->height == $self->height) {
                            $self->received_from->send_line("abort incorrect_block") if $self->received_from;
                            return -1;
                        }
                        # Ok, it's theoretically possible that branch from $new_best to $b->prev_block is better than our best branch.
                        # But we have not all blocks there, so we can switch to this branch (or keep in our best) later,
                        # not needed to change the best branch immediately.
                        if ($self->received_from) {
                            $self->received_from->send_line("sendblock " . $b->height);
                        }
                        return 0;
                    }
                }
            }
        }

        # set best branch
        for (my $b = $self; $b && (!$best_block[$b->height] || $best_block[$b->height]->hash ne $b->hash); $b = $b->prev_block) {
            $best_block[$b->height] = $b;
            if ($b->prev_block && (!$b->prev_block->next_block || $b->prev_block->next_block->hash ne $b->hash)) {
                $b->prev_block->next_block = $b;
            }
            last if !$best_block[$b->height-1];
        }
        for (my $b = $self->next_block; $b; $b = $b->next_block) {
            $best_block[$b->height] = $b;
        }
        if (defined($height) && $self->height <= $height) {
            QBitcoin::Generate::Control->generate_new() if $new_best->height < $height;
            Debugf("%s block height %u hash %s, best branch altered, weight %u, %u transactions",
                $self->received_from ? "received" : "loaded", $self->height,
                $self->hash_out, $self->branch_weight, scalar(@{$self->transactions}));
        }
        else {
            Debugf("%s block height %u hash %s in best branch, weight %u, %u transactions",
                $self->received_from ? "received" : "loaded", $self->height,
                $self->hash_out, $self->branch_weight, scalar(@{$self->transactions}));
        }
        my $old_height = $height // -1;
        $height = $self->branch_height();
        if ($height > $old_height) {
            # It's the first block in this level
            # Store and free old level (if it's linked and in best branch)
            if ($self->received_from && $height >= $declared_height && !blockchain_synced()) {
                Infof("Blockchain is synced");
                blockchain_synced(1);
            }
            if ((my $first_free_height = $height - INCORE_LEVELS) >= 0) {
                if ($best_block[$first_free_height]) {
                    $best_block[$first_free_height]->store();
                    $best_block[$first_free_height] = undef;
                }
                # Remove linked blocks and branches with weight less than our best for all levels below $free_height
                # Keep only unlinked branches with weight more than our best and have blocks within last INCORE_LEVELS
                for (my $free_height = $first_free_height; $free_height >= 0; $free_height--) {
                    last unless $block_pool[$free_height];
                    foreach my $b (values %{$block_pool[$free_height]}) {
                        if ($b->branch_weight > $best_block[$height]->weight &&
                            $b->branch_height > $first_free_height) {
                            next;
                        }
                        delete $block_pool[$free_height]->{$b->hash};
                        delete $prev_block[$free_height]->{$b->prev_hash}->{$b->hash} if $b->prev_hash;
                        $b->next_block(undef);
                        foreach my $b2 (values %{$prev_block[$free_height+1]->{$b->hash}}) {
                            $b2->prev_block(undef);
                        }
                        foreach my $tx (@{$b->transactions}) {
                            $tx->free();
                        }
                    }
                    foreach my $prev_hash (keys %{$prev_block[$free_height]}) {
                        delete $prev_block[$free_height]->{$prev_hash} unless %{$prev_block[$free_height]->{$prev_hash}};
                    }
                    if (!%{$block_pool[$free_height]}) {
                        $prev_block[$free_height] = undef;
                        $block_pool[$free_height] = undef;
                    }
                }
            }
        }

        if ($self->received_from && blockchain_synced()) {
            # Do not announce blocks loaded from local database
            $self->announce_to_peers();
        }

        my $branch_height = $self->branch_height();
        if ($self->received_from && time() >= time_by_height($branch_height+1)) {
            $self->received_from->send_line("sendblock " . ($branch_height+1));
        }
    }
    return 0;
}

sub prev_block {
    my $self = shift;
    if (@_) {
        if ($_[0]) {
            $_->[0]->hash eq $_->prev_hash
                or die "Incorrect block linking";
            return $self->{prev_block} = $_[0];
        }
        else {
            # It's not set "unexising" prev, it's free pointer which will be load again on demand
            delete $self->{prev_block}; # load again on demand
            return undef;
        }
    }
    return $self->{prev_block} if exists $self->{prev_block}; # undef means we have no such block
    return undef unless $self->height; # genesis block has no ancestors
    my $class = ref($self);
    return $self->{prev_block} //= $block_pool[$self->height-1]->{$self->prev_hash} //
        $class->find(hash => $self->prev_hash);
}

sub drop_branch {
    my $self = shift;

    $self->prev_block(undef);
    delete $block_pool[$self->height]->{$self->hash};
    delete $prev_block[$self->height]->{$self->prev_hash}->{$self->hash};
    foreach my $descendant (values %{$prev_block[$self->height+1]->{$self->hash}}) {
        $descendant->drop_branch(); # recursively
    }
}

sub set_linked {
    my $self = shift;

    if ($self->validate_tx != 0) {
        $self->drop_branch;
        return -1;
    }
    $self->linked = 1;
    if ($prev_block[$self->height+1] && (my $descendants = $prev_block[$self->height+1]->{$self->hash})) {
        foreach my $descendant (values %$descendants) {
            $descendant->set_linked(); # recursively
        }
    }
    return 0;
}

sub announce_to_peers {
    my $self = shift;

    foreach my $peer (QBitcoin::Peers->peers) {
        next if $self->received_from && $peer->ip eq $self->received_from->ip;
        $peer->send_line("ihave " . $self->height . " " . $self->weight);
    }
}

1;
