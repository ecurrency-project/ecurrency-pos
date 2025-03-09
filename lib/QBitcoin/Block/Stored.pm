package QBitcoin::Block::Stored;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::ORM qw(find replace delete);
use QBitcoin::ORM::Transaction;

use constant TABLE => 'block';

my $MAX_DB_HEIGHT;

sub store {
    my $self = shift;
    my $db_transaction = QBitcoin::ORM::Transaction->new;
    $self->replace(); # Save block first to satisfy foreign key
    foreach my $transaction (@{$self->transactions}) {
        $transaction->store();
    }
    $db_transaction->commit;
    $MAX_DB_HEIGHT = $self->height if !defined($MAX_DB_HEIGHT) || $MAX_DB_HEIGHT < $self->height;
}

sub transactions {
    my $self = shift;
    if (@_) {
        $self->{transactions} = $_[0];
    }
    elsif (!$self->{transactions}) {
        if ($self->{tx_by_hash}) {
            die "Get transactions from not-loaded block\n";
        }
        my @transactions = QBitcoin::Transaction->find(block_height => $self->height, -sortby => 'block_pos ASC');
        if ($self->is_cached) {
            foreach my $transaction (@transactions) {
                # It's possible that the transaction already loaded if it's included in some alternative branch
                $transaction->add_to_cache() unless $transaction->is_cached;
                $transaction->add_to_block($self);
            }
        }
        $self->{transactions} = \@transactions;
    }
    return $self->{transactions};
}

sub tx_hashes {
    my $self = shift;
    return $self->{tx_hashes} //=
        $self->{transactions} ?
            [ map { $_->hash } @{$self->{transactions}} ] :
            [ map { $_->{hash} } QBitcoin::Transaction->fetch(block_height => $self->height, -sortby => 'block_pos ASC') ];
}

sub max_db_height {
    my $class = shift;
    if (@_) {
        $MAX_DB_HEIGHT = $_[0];
    }
    return $MAX_DB_HEIGHT // -1;
}

1;
