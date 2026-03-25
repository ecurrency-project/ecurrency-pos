package QBitcoin::CheckPoints;
use warnings;
use strict;

use QBitcoin::Config;

use Exporter qw(import);
our @EXPORT_OK = qw(checkpoint_hash max_checkpoint_height upgrade_finished);

use constant CHECKPOINTS => {
    # height => pack('H*', "block_hash_hex"),
};

use constant CHECKPOINTS_TESTNET => {
};

use constant UPGRADE_FINISHED         => 0; # Set to 1 when all upgrades are in a checkpoint
use constant UPGRADE_FINISHED_TESTNET => 0;

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

sub upgrade_finished {
    return $config->{regtest} ? 0 : $config->{testnet} ? UPGRADE_FINISHED_TESTNET : UPGRADE_FINISHED;
}

1;
