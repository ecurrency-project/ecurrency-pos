package QBitcoin::TXO::My;
use warnings;
use strict;
use feature 'state';

use Role::Tiny;

use QBitcoin::Log;
use QBitcoin::MyAddress;

my %MY_UTXO;
my %STAKED_UTXO;

sub _in_key {
    my $self = shift;
    return $self->tx_in . $self->num;
}

sub add_my_utxo {
    my $self = shift;
    if ($self->is_staked) {
        $STAKED_UTXO{$self->_in_key} = $self if $self->is_staked;
        Infof("Add staked UTXO %s:%u %lu coins", $self->tx_in_str, $self->num, $self->value);
    }
    else {
        $MY_UTXO{$self->_in_key} = $self;
        Infof("Add my UTXO %s:%u %lu coins", $self->tx_in_str, $self->num, $self->value);
    }
}

sub del_my_utxo {
    my $self = shift;
    if (delete $MY_UTXO{$self->_in_key}) {
        Infof("Delete my UTXO %s:%u %lu coins", $self->tx_in_str, $self->num, $self->value);
    }
    elsif (delete $STAKED_UTXO{$self->_in_key}) {
        Infof("Delete staked UTXO %s:%u %lu coins", $self->tx_in_str, $self->num, $self->value);
    }
}

sub my_utxo {
    return (values(%MY_UTXO), values(%STAKED_UTXO));
}

sub is_staked {
    my $self = shift;
    my $my_address = QBitcoin::MyAddress->get_by_hash($self->scripthash);
    return $my_address && $my_address->staked;
}

sub staked_utxo {
    return values %STAKED_UTXO;
}

sub is_my {
    my $self = shift;
    return !!QBitcoin::MyAddress->get_by_hash($self->scripthash);
}

1;
