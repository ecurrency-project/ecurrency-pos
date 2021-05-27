package QBitcoin::Block::Validate;
use warnings;
use strict;

# Check block chain
# Check block time
# Validate all transactions
# Amount of all commissions should be 0

use QBitcoin::Const;
use Role::Tiny;

sub validate {
    my $block = shift;

    my $now = time();
    $now >= time_by_height($block->height)
        or return "Block height " . $block->height . " is too early for now";
    if ($block->height == 0) {
#        $block->hash eq GENESIS_HASH
#            or return "Incorrect genesis block hash " . unpack("H*", $block->hash) . ", must be " . GENESIS_HASH_HEX;
        return ""; # Not needed to validate genesis block with correct hash
    }
    my $fee = 0;
    my %tx_in_block;
    foreach my $transaction (@{$block->transactions}) {
        if ($tx_in_block{$transaction->hash}++) {
            return "Transaction " . $transaction->hash_out . " included in the block twice";
        }
        if ($transaction->validate != 0) {
            return "Incorrect transaction " . $transaction->hash_out;
        }
        # NB: we do not check that the $txin is unspent in this branch;
        # we will check this on include this block into the best branch
        $fee += $transaction->fee;
    }
    $fee == 0
        or return "Total block fee is $fee (not 0)";
    return "";
}

sub validate_tx {
    my $self = shift;
    # TODO
    return 0;
}

1;
