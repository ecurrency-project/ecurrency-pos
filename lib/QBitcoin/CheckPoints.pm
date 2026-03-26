package QBitcoin::CheckPoints;
use warnings;
use strict;

use QBitcoin::Config;

use Exporter qw(import);
our @EXPORT_OK = qw(checkpoint_hash max_checkpoint_height prev_checkpoint_height upgrade_finished);

use constant CHECKPOINTS => {
    # height => pack('H*', "block_hash_hex"),
    1000000 => pack("H*", "17f97cf4a7bda6c31379e185a314fc6e47d6c4987b0f7bc4816c69420537c668"),
};

use constant CHECKPOINTS_TESTNET => {
    150000 => pack("H*", "be4125eb25b4e527f3b87108245ddd6c18875c15b8b6451502b03d8f5eb54667"),
};

use constant UPGRADE_FINISHED         => 1; # Set to 1 when all upgrades are in a checkpoint
use constant UPGRADE_FINISHED_TESTNET => 0;

my $checkpoints;
my $max_checkpoint_height;
my @sorted_checkpoint_heights;

sub _init_checkpoints {
    $checkpoints = $config->{regtest} ? {} : $config->{testnet} ? CHECKPOINTS_TESTNET : CHECKPOINTS;
    @sorted_checkpoint_heights = sort { $a <=> $b } keys %$checkpoints;
    $max_checkpoint_height = @sorted_checkpoint_heights ? $sorted_checkpoint_heights[-1] : -1;
}

sub checkpoint_hash {
    _init_checkpoints() if !defined $checkpoints;
    return $checkpoints->{$_[0]};
}

sub max_checkpoint_height {
    _init_checkpoints() if !defined $max_checkpoint_height;
    return $max_checkpoint_height;
}

sub prev_checkpoint_height {
    _init_checkpoints() if !defined $checkpoints;
    my ($height) = @_;
    my $prev = -1;
    for my $cp_height (@sorted_checkpoint_heights) {
        last if $cp_height >= $height;
        $prev = $cp_height;
    }
    return $prev;
}

sub upgrade_finished {
    return $config->{regtest} ? 0 : $config->{testnet} ? UPGRADE_FINISHED_TESTNET : UPGRADE_FINISHED;
}

1;
