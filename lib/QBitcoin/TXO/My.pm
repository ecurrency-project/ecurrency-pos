package QBitcoin::TXO::My;
use warnings;
use strict;

# Wallet-facing facade composed into QBitcoin::TXO: joins a txo with the
# wallet addresses and delegations (is_my, my_roles) and delegates the
# my-utxo bookkeeping to the QBitcoin::Wallet::UTXO registry.

use Role::Tiny;

# Call the registry functions fully qualified: Role::Tiny composes all subs
# from the role package into the consumer, so importing them here would turn
# them into QBitcoin::TXO methods
use QBitcoin::MyAddress;
use QBitcoin::Delegation;
use QBitcoin::Wallet::UTXO ();

# Bitmask of QBitcoin::Wallet::UTXO roles for this output; 0 for a foreign one
sub my_roles {
    my $self = shift;
    my $roles = 0;
    if (my $my_address = QBitcoin::MyAddress->get_by_hash($self->scripthash, 0)) {
        $roles |= $my_address->staked ? QBitcoin::Wallet::UTXO::UTXO_STAKED : QBitcoin::Wallet::UTXO::UTXO_MY;
    }
    if (QBitcoin::Delegation->get_by_hash($self->scripthash)) {
        $roles |= QBitcoin::Wallet::UTXO::UTXO_DELEGATED;
    }
    return $roles;
}

sub add_my_utxo {
    my $self = shift;
    QBitcoin::Wallet::UTXO::myutxo_add($self, $self->my_roles);
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

sub is_my {
    my $self = shift;
    return !!$self->my_roles;
}

sub is_delegated {
    my $self = shift;
    return !!QBitcoin::Delegation->get_by_hash($self->scripthash);
}

1;
