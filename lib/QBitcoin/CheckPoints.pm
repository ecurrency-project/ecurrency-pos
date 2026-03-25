package QBitcoin::CheckPoints;
use warnings;
use strict;

use QBitcoin::Config;

use Exporter qw(import);
our @EXPORT_OK = qw(checkpoint_hash max_checkpoint_height);

use constant CHECKPOINTS => {
    # height => pack('H*', "block_hash_hex"),
};

use constant CHECKPOINTS_TESTNET => {
};

my $checkpoints;
my $max_checkpoint_height;

sub _init_checkpoints {
    $checkpoints = $config->{regtest} ? {} : $config->{testnet} ? CHECKPOINTS_TESTNET : CHECKPOINTS;
    $max_checkpoint_height = %$checkpoints ? (sort { $b <=> $a } keys %$checkpoints)[0] : -1;
}

sub checkpoint_hash {
    _init_checkpoints() if !defined $checkpoints;
    return $checkpoints->{$_[0]};
}

sub max_checkpoint_height {
    _init_checkpoints() if !defined $max_checkpoint_height;
    return $max_checkpoint_height;
}

1;
