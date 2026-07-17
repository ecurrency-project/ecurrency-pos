package QBitcoin::Block::Pending;
use warnings;
use strict;

use Tie::IxHash;
use QBitcoin::Const;
use QBitcoin::Log;
use Role::Tiny;

my %PENDING_BLOCK;
tie(%PENDING_BLOCK, 'Tie::IxHash'); # Ordered by age
my %PENDING_TX_BLOCK;
my %PENDING_BLOCK_BLOCK;

sub add_pending {
    my $self = shift;

    $PENDING_BLOCK{$self->hash} //= $self;

    if (keys %PENDING_BLOCK > MAX_PENDING_BLOCKS) {
        my ($oldest_block) = values %PENDING_BLOCK;
        $oldest_block->drop_pending();
    }
    $self->received_from->has_pending(1) if $self->received_from;
}

sub add_pending_block {
    my $self = shift;
    $PENDING_BLOCK_BLOCK{$self->prev_hash}->{$self->hash} = 1;
    $self->add_pending();
}

sub pending_descendants {
    my $self = shift;

    if (my $pending = $PENDING_BLOCK_BLOCK{$self->hash}) {
        return map { $PENDING_BLOCK{$_} } keys %$pending;
    }
    else {
        return ();
    }
}

sub drop_pending {
    my $self = shift;
    # and drop all blocks pending by this one
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels

    foreach my $next_block ($self->pending_descendants()) {
        $next_block->drop_pending();
    }
    if ($PENDING_BLOCK{$self->hash}) {
        Debugf("Drop pending block %s", $self->hash_str);
        if ($self->pending_tx) {
            foreach my $tx_hash ($self->pending_tx) {
                delete $PENDING_TX_BLOCK{$tx_hash}->{$self->hash};
                if (!%{$PENDING_TX_BLOCK{$tx_hash}}) {
                    delete $PENDING_TX_BLOCK{$tx_hash};
                }
            }
        }
        if ($self->prev_hash && $PENDING_BLOCK_BLOCK{$self->prev_hash}) {
            delete $PENDING_BLOCK_BLOCK{$self->prev_hash}->{$self->hash};
            if (!%{$PENDING_BLOCK_BLOCK{$self->prev_hash}}) {
                delete $PENDING_BLOCK_BLOCK{$self->prev_hash};
            }
        }
        $self->free_tx();
        $self->del_as_descendant();
    }
    delete $PENDING_BLOCK{$self->hash};
}

sub process_pending {
    my $self = shift;
    my ($peer) = @_; # protocol which triggered the processing, the current driver of the branch
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels

    # change recursion to loop by chain of pending blocks to avoid too deep recursion
    my $block = $self;
    while (1) {
        my $pending = delete $PENDING_BLOCK_BLOCK{$block->hash}
            or return $block;
        my @hashes = keys %$pending;
        my $block_next;
        while (my $hash = pop @hashes) {
            my $pending_block = $PENDING_BLOCK{$hash};
            $pending_block->prev_block($block);
            $pending_block->add_as_descendant();
            if ($pending_block->pending_tx) {
                if (!$pending_block->{pending_tx_requested}) {
                    my $from = $peer && $peer->connection ? $peer
                        : $pending_block->received_from && $pending_block->received_from->connection
                            ? $pending_block->received_from : undef;
                    if ($from) {
                        $from->request_tx($pending_block->pending_tx);
                        $pending_block->{pending_tx_requested} = 1;
                    }
                }
                next;
            }
            delete $PENDING_BLOCK{$hash};
            Debugf("Process block %s height %u pending for received %s", $pending_block->hash_str, $pending_block->height, $block->hash_str);
            $pending_block->compact_tx();
            if ($pending_block->receive() == 0) {
                if ($block_next) {
                    $pending_block->process_pending($peer); # recursve
                }
                else {
                    $block_next = $pending_block;
                }
            }
            else {
                $pending_block->drop_pending();
            }
        }
        return $block unless $block_next;
        $block = $block_next;
    }
}

sub is_pending {
    my $self = shift;
    return !!$PENDING_BLOCK{$_[0] // $self->hash};
}

sub recv_pending_tx {
    my $class = shift;
    my ($tx) = @_;
    my $height;
    if (my $blocks = delete $PENDING_TX_BLOCK{$tx->hash}) {
        foreach my $block_hash (keys %$blocks) {
            my $block = $PENDING_BLOCK{$block_hash};
            if (!$block) {
                # In rare cases the block may be dropped by previous iteration of this loop
                Debugf("Block %s pending for received tx %s not found (was already dropped?)",
                    QBitcoin::Block->hash_str($block_hash), $tx->hash_str);
                next;
            }
            Debugf("Block %s is pending received tx %s", $block->hash_str, $tx->hash_str);
            $block->add_tx($tx);
            if (!$block->pending_tx && (!$block->prev_hash || !$PENDING_BLOCK_BLOCK{$block->prev_hash})) {
                delete $PENDING_BLOCK{$block->hash};
                $block->compact_tx();
                if ($block->receive() == 0) {
                    $block = $block->process_pending($tx->received_from);
                    $height = $block->height if !defined($height) || $height < $block->height;
                }
                else {
                    $block->drop_pending();
                    return -1;
                }
            }
        }
    }
    return $height;
}

sub load_transactions {
    my $self = shift;
    if (!$self->pending_tx) {
        foreach my $tx_hash (@{$self->tx_hashes}) {
            my $transaction = QBitcoin::Transaction->get_by_hash($tx_hash);
            if ($transaction) {
                $transaction->add_to_cache() unless $transaction->is_cached;
                $self->add_tx($transaction);
            }
            else {
                $self->pending_tx($tx_hash);
                $PENDING_TX_BLOCK{$tx_hash}->{$self->hash} = 1;
                Debugf("Set pending_tx %s block %s time %u", unpack("H*", substr($tx_hash, 0, 4)), $self->hash_str, $self->time);
            }
        }
        if ($self->pending_tx) {
            $self->add_pending();
        }
    }
    return ();
}

sub drop_all_pending {
    my $class = shift;
    my ($connection) = @_;

    my $requested = 0;
    foreach my $block_hash (keys %PENDING_BLOCK) {
        my $block = $PENDING_BLOCK{$block_hash}
            or next; # already dropped?
        if ($block->received_from->peer->id eq $connection->peer->id) {
            $block->drop_pending();
        }
    }
}

1;
