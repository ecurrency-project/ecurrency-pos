package QBitcoin::ProtocolState;
use warnings;
use strict;

my $mempool_synced;
my $blockchain_synced;
my $btc_synced;

use Exporter qw(import);
our @EXPORT_OK = qw(mempool_synced blockchain_synced btc_synced);

sub mempool_synced {
    if (@_) {
        $mempool_synced = $_[0];
    }
    return $mempool_synced;
}

sub blockchain_synced {
    if (@_) {
        $blockchain_synced = $_[0];
    }
    return $blockchain_synced;
}

sub btc_synced {
    if (@_) {
        $btc_synced = $_[0];
    }
    return $btc_synced;
}

1;
