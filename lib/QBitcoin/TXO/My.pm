package QBitcoin::TXO::My;
use warnings;
use strict;

# Wallet-facing facade composed into QBitcoin::TXO: joins a txo with the
# wallet addresses (is_my, is_staked) and delegates the my-utxo bookkeeping
# to the QBitcoin::Wallet::UTXO registry.

use Role::Tiny;

# Call the registry functions fully qualified: Role::Tiny composes all subs
# from the role package into the consumer, so importing them here would turn
# them into QBitcoin::TXO methods
use QBitcoin::MyAddress;
use QBitcoin::Wallet::UTXO ();

sub add_my_utxo {
    my $self = shift;
    QBitcoin::Wallet::UTXO::myutxo_add($self, $self->is_staked);
}

sub del_my_utxo {
    my $self = shift;
    QBitcoin::Wallet::UTXO::myutxo_del($self);
}

sub my_utxo {
    return QBitcoin::Wallet::UTXO::myutxo_list();
}

sub staked_utxo {
    return QBitcoin::Wallet::UTXO::myutxo_staked();
}

sub is_staked {
    my $self = shift;
    my $my_address = QBitcoin::MyAddress->get_by_hash($self->scripthash, 0);
    return $my_address && $my_address->staked;
}

sub is_my {
    my $self = shift;
    return !!QBitcoin::MyAddress->get_by_hash($self->scripthash, 0);
}

1;
