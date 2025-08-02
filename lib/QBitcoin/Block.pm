package QBitcoin::Block;
use warnings;
use strict;

use QBitcoin::Const;
use QBitcoin::ORM qw(:types);
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::Config;
use QBitcoin::Transaction;

use Role::Tiny::With;
with 'QBitcoin::Block::Receive';
with 'QBitcoin::Block::Validate';
with 'QBitcoin::Block::Serialize';
with 'QBitcoin::Block::Stored';
with 'QBitcoin::Block::MerkleTree';
with 'QBitcoin::Block::Pending';

use constant PRIMARY_KEY => 'height';

use constant FIELDS => {
    height      => NUMERIC,
    time        => NUMERIC,
    hash        => BINARY,
    size        => NUMERIC,
    weight      => NUMERIC,
    upgraded    => NUMERIC,
    reward_fund => NUMERIC,
    min_fee     => NUMERIC,
    prev_hash   => BINARY,
    merkle_root => BINARY,
};

use constant ATTR => qw(
    next_block
    received_from
    rcvd
);

mk_accessors(keys %{&FIELDS});
mk_accessors(ATTR);

sub branch_height {
    my $self = shift;
    while ($self->next_block) {
        $self = $self->next_block;
    }
    return $self->height;
}

sub self_weight {
    my $self = shift;
    if (!defined $self->{self_weight}) {
        if (@{$self->transactions}) {
            if (defined(my $stake_weight = $self->transactions->[0]->stake_weight($self))) {
                $self->{self_weight} = $stake_weight + @{$self->transactions};
                # coinbase increases block weight
                foreach my $transaction (@{$self->transactions}) {
                    if (!$transaction->coins_created) {
                        last if $transaction->fee >= 0;
                        next;
                    }
                    $self->{self_weight} += $transaction->coinbase_weight($self->time);
                }
            }
            # otherwise we have unknown input in stake transaction; return undef and calculate next time
        }
        else {
            $self->{self_weight} = 0;
        }
    }
    return $self->{self_weight};
}

sub add_tx {
    my $self = shift;
    my ($tx) = @_;
    $self->{tx_by_hash} //= {};
    $self->{tx_by_hash}->{$tx->hash} = $tx;
    $tx->add_to_block($self);
    delete $self->{pending_tx}->{$tx->hash} if $self->pending_tx;
}

sub pending_tx {
    my $self = shift;
    my ($tx_hash) = @_;
    if ($tx_hash) {
        $self->{pending_tx} //= {};
        $self->{pending_tx}->{$tx_hash} = 1;
        return 1;
    }
    else {
        return $self->{pending_tx} && %{$self->{pending_tx}} ? keys %{$self->{pending_tx}} : ();
    }
}

sub compact_tx {
    my $self = shift;
    if ($self->{transactions}) {
        die "Call compact_tx with already defined transactions for block " . $self->hash_str . " height " . $self->height . "\n";
    }
    $self->{transactions} = [ map { $self->{tx_by_hash}->{$_} } @{$self->{tx_hashes}} ];
    delete $self->{tx_by_hash};
}

sub free_tx {
    my $self = shift;
    # works for pending block too
    if ($self->{transactions}) {
        foreach my $tx (@{$self->{transactions}}) {
            $tx->del_from_block($self);
        }
    }
    elsif ($self->{tx_by_hash}) {
        foreach my $tx (values %{$self->{tx_by_hash}}) {
            $tx->del_from_block($self);
        }
    }
}

sub sign_data {
    my $self = shift;
    my $data = $self->prev_hash // ZERO_HASH;
    my $num = 0;
    foreach (@{$self->tx_hashes}) {
        $data .= $_ if $num++;
    }
    return $data;
}

sub hash_str {
    my $arg  = pop;
    my $hash = ref($arg) ? $arg->hash : $arg;
    return unpack("H*", substr($hash, 0, 4));
}

sub reward {
    my $class = shift;
    my ($prev_block, $fee) = @_;
    if ($prev_block) {
        my $reward_fund = $prev_block->reward_fund + $fee
            or return 0;
        return int($reward_fund / REWARD_DIVIDER) || 1;
    }
    else {
        return $config->{regtest} ? $config->{genesis_reward} // 0 : GENESIS_REWARD;
    }
}

sub reorg_penalty {
    my $self = shift;
    my ($branch_start) = @_;

    # It's not consensus rule, so we're able to use floating point arithmetic here
    # It should be overweight twice for revert last 16 blocks, 4 times for 32 blocks, 8 times for 64 blocks, 16 times for 128 blocks, 32 times for 256 blocks
    # But then decrease for prevent split-brain: 32 times for 900; 16 times for 3600; 8 times for 14400 blocks (~1 day), 4 times for 57600 blocks, 2 times for 230400 blocks, and no penalty for 921600 blocks (~3 months)

    return 0 if $self->height - $branch_start->height < INCORE_LEVELS;
    my $reorg_blocks = (timeslot($self->time) - timeslot($branch_start->time)) / BLOCK_INTERVAL - INCORE_LEVELS;
    my $coef;
    if ($reorg_blocks < 256) {
        $coef = $reorg_blocks / 8;
    }
    elsif ($reorg_blocks < 900) {
        $coef = 32;
    }
    elsif ($reorg_blocks < 921600) {
        $coef = 960 / sqrt($reorg_blocks);
    }
    else {
        $coef = 1;
    }
    Debugf("Reorg penalty for block %s height %u (%u reorg blocks, %u seconds): %.2f%%\n",
        $self->hash_str, $self->height, $self->height - $branch_start->height,
        $self->time - $branch_start->time, ($coef - 1) * 100);
    return ($coef - 1) * ($self->weight - $branch_start->weight);
}

1;
