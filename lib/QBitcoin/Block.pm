package QBitcoin::Block;
use warnings;
use strict;

use QBitcoin::ORM qw(:types);
use QBitcoin::Accessors qw(mk_accessors new);

use Role::Tiny::With;
with 'QBitcoin::Block::Receive';
with 'QBitcoin::Block::Validate';
with 'QBitcoin::Block::Serialize';
with 'QBitcoin::Block::Stored';

use constant PRIMARY_KEY => 'height';

use constant FIELDS => {
    height    => NUMERIC,
    hash      => BINARY,
    prev_hash => BINARY,
    weight    => NUMERIC,
};

use constant ATTR => qw(
    linked
    next_block
    received_from
    transactions
);

mk_accessors(keys %{&FIELDS});
mk_accessors(ATTR);

sub branch_weight {
    my $self = shift;
    while ($self->next_block) {
        $self = $self->next_block;
    }
    return $self->weight;
}

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
            if (defined(my $stake_weight = $self->transactions->[0]->stake_weight($self->height))) {
                $self->{self_weight} = $stake_weight + @{$self->transactions};
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
    delete $self->{pending_tx}->{$tx->hash} if $self->pending_tx;
}

sub pending_tx {
    my $self = shift;
    my ($tx_hash) = @_;
    if ($tx_hash) {
        $self->{pending_tx}->{$tx_hash} = 1;
        return 1;
    }
    else {
        return $self->{pending_tx} && %{$self->{pending_tx}} ? [ keys %{$self->{pending_tx}} ] : undef;
    }
}

sub compact_tx {
    my $self = shift;
    $self->{transactions} = [ map { $self->{tx_by_hash}->{$_} } @{$self->{tx_hashes}} ];
    delete $self->{tx_hashes};
    delete $self->{tx_by_hash};
}

sub tx_hashes {
    my $self = shift;
    return $self->{tx_hashes} //
        [ map { $_->hash } @{$self->{transactions}} ];
}

sub hash_str {
    my $arg  = pop;
    my $hash = ref($arg) ? $arg->hash : $arg;
    return unpack("H*", substr($hash, 0, 4));
}

1;
