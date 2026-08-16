package QBitcoin::Wallet::UTXO;
use warnings;
use strict;

# In-memory registry of unspent outputs the wallet tracks. Pure container:
# which roles a txo has is decided by the caller (QBitcoin::TXO::My->my_roles
# for the usual add/del, QBitcoin::MyAddress on stake flag change).
# Stored values are QBitcoin::TXO objects, but only their instance methods are
# called here, so this module depends on neither TXO nor MyAddress.
#
# Roles are a bitmask; an output may be both MY and DELEGATED when the node
# holds the owner key of an address delegated to it for staking:
# - MY:        spendable by a wallet key, counted in the balance;
# - STAKED:    an own address used for staking (also counted in the balance);
# - DELEGATED: delegated to this node for staking; not our money.

use QBitcoin::Log;

use Exporter qw(import);
our @EXPORT_OK = qw(
    myutxo_add
    myutxo_del
    myutxo_list
    myutxo_staked
    myutxo_delegated
    UTXO_MY
    UTXO_STAKED
    UTXO_DELEGATED
);

use constant {
    UTXO_MY        => 1,
    UTXO_STAKED    => 2,
    UTXO_DELEGATED => 4,
};

my %MY_UTXO;
my %STAKED_UTXO;
my %DELEGATED_UTXO;

sub myutxo_add {
    my ($txo, $roles) = @_;
    if ($roles & UTXO_MY) {
        $MY_UTXO{$txo->key} = $txo;
        Infof("Add my UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
    if ($roles & UTXO_STAKED) {
        $STAKED_UTXO{$txo->key} = $txo;
        Infof("Add staked UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
    if ($roles & UTXO_DELEGATED) {
        $DELEGATED_UTXO{$txo->key} = $txo;
        Infof("Add delegated UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
}

sub myutxo_del {
    my ($txo) = @_;
    if (delete $MY_UTXO{$txo->key}) {
        Infof("Delete my UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
    if (delete $STAKED_UTXO{$txo->key}) {
        Infof("Delete staked UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
    if (delete $DELEGATED_UTXO{$txo->key}) {
        Infof("Delete delegated UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
}

# NB: these return a named array, not the bare "values(%a), values(%b)" list. Callers use
# them in boolean and numeric context too ("do we have anything to stake with?"), and a list
# in scalar context is the comma operator: it yields only its LAST element, i.e. the size of
# the second hash alone. A node staking its own coins with no delegations then looked like it
# had no stake sources at all.
#
# Own coins: the wallet balance and spendable-output selection
sub myutxo_list {
    my @utxo = (values(%MY_UTXO), values(%STAKED_UTXO));
    return @utxo;
}

# Stake sources: own staked coins plus coins delegated to this node.
# An output present in both MY and DELEGATED is returned once (as delegated).
sub myutxo_staked {
    my @utxo = (values(%STAKED_UTXO), values(%DELEGATED_UTXO));
    return @utxo;
}

sub myutxo_delegated {
    return values %DELEGATED_UTXO;
}

1;
