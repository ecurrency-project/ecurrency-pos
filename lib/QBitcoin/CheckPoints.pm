package QBitcoin::CheckPoints;
use warnings;
use strict;

use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;

use Exporter qw(import);
our @EXPORT_OK = qw(checkpoint_hash max_checkpoint_height prev_checkpoint_height);

my $checkpoints;
my $max_checkpoint_height;
my @sorted_checkpoint_heights;

sub _init_checkpoints {
    $checkpoints = CHECKPOINTS;
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
    foreach my $cp_height (@sorted_checkpoint_heights) {
        last if $cp_height >= $height;
        $prev = $cp_height;
    }
    return $prev;
}

1;
