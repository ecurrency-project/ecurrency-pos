package QBitcoin::ProtocolState;
use warnings;
use strict;

my $mempool_synced;
my $blockchain_synced;
my $btc_synced;
my $skip_scripts;

use Exporter qw(import);
our @EXPORT_OK = qw(mempool_synced blockchain_synced btc_synced skip_scripts);

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

sub skip_scripts {
    if (@_) {
        $skip_scripts = $_[0];
    }
    return $skip_scripts;
}

1;
