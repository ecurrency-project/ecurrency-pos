package QBitcoin::Wallet::UTXO;
use warnings;
use strict;

# In-memory registry of unspent outputs belonging to the wallet addresses,
# regular and staked separately. Pure container: whether a txo belongs to the
# wallet and whether it is staked is decided by the caller (QBitcoin::TXO::My
# for the usual add/del, QBitcoin::MyAddress on stake flag change).
# Stored values are QBitcoin::TXO objects, but only their instance methods are
# called here, so this module depends on neither TXO nor MyAddress.

use QBitcoin::Log;

use Exporter qw(import);
our @EXPORT_OK = qw(
    myutxo_add
    myutxo_del
    myutxo_list
    myutxo_staked
);

my %MY_UTXO;
my %STAKED_UTXO;

sub _in_key {
    my ($txo) = @_;
    return $txo->tx_in . $txo->num;
}

sub myutxo_add {
    my ($txo, $staked) = @_;
    if ($staked) {
        $STAKED_UTXO{_in_key($txo)} = $txo;
        Infof("Add staked UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
    else {
        $MY_UTXO{_in_key($txo)} = $txo;
        Infof("Add my UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
}

sub myutxo_del {
    my ($txo) = @_;
    if (delete $MY_UTXO{_in_key($txo)}) {
        Infof("Delete my UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
    elsif (delete $STAKED_UTXO{_in_key($txo)}) {
        Infof("Delete staked UTXO %s:%u %lu coins", $txo->tx_in_str, $txo->num, $txo->value);
    }
}

sub myutxo_list {
    return (values(%MY_UTXO), values(%STAKED_UTXO));
}

sub myutxo_staked {
    return values %STAKED_UTXO;
}

1;
