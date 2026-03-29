package QBitcoin::Revalidate;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::ProtocolState qw(skip_scripts);
use QBitcoin::CheckPoints qw(checkpoint_hash max_checkpoint_height);
use QBitcoin::Block;
use QBitcoin::Transaction;

use Exporter qw(import);
our @EXPORT_OK = qw(revalidate);

sub revalidate {
    # TODO: rescan btc blocks
    Info("Revalidating stored blocks");
    my $tx_class = "QBitcoin::Transaction";
    my $portion = 100;
    my $bad_height;
    my $prev_block;
    for (my $start_block = 0;; $start_block += $portion) {
        my @blocks = QBitcoin::Block->find( height => { '>=', $start_block }, -limit => $portion, -sortby => 'height' )
            or last;
        my $block_count = scalar @blocks;
        while (my $block = shift @blocks) {
            if ($prev_block) {
                if ($block->prev_hash ne $prev_block->hash || $block->height != $prev_block->height + 1) {
                    $bad_height = $block->height;
                    last;
                }
                $block->prev_block($prev_block);
                $prev_block->prev_block(undef);
            }
            else {
                if ($block->height != 0) {
                    $bad_height = $block->height;
                    last;
                }
            }
            my $upgraded = $block->upgraded;
            my $reward_fund = $block->reward_fund;
            my $size = $block->size;
            my $min_fee = $block->min_fee;
            my $checkpointed = $block->height <= max_checkpoint_height();
            skip_scripts($checkpointed ? 1 : 0);
            my @txs;
            foreach my $txhash ($tx_class->fetch(block_height => $block->height, -sortby => 'block_pos ASC')) {
                $tx_class->pre_load($txhash);
                my $tx = $tx_class->new($txhash);
                my $hash = $tx->hash;
                if ($tx->validate_hash or (!$checkpointed && $tx->validate)) {
                    Warningf("Invalid hash for loaded transaction %s != %s", unpack("H*", $hash), $tx->hash_str);
                    $bad_height = $block->height;
                    last;
                }
                push @txs, $tx;
                $tx->add_to_block($block);
            }
            $block->transactions(\@txs);
            if ($checkpointed) {
                if ( defined($bad_height) ||
                     $block->hash ne $block->calculate_hash ||
                     (checkpoint_hash($block->height) && $block->hash ne checkpoint_hash($block->height))) {
                    $bad_height = $block->height;
                }
            }
            else {
                if ( defined($bad_height) ||
                     $block->hash ne $block->calculate_hash ||
                     $block->validate() ||
                     $block->validate_chain() ||
                     $block->upgraded != $upgraded ||
                     $block->reward_fund != $reward_fund ||
                     $block->size != $size ||
                     $block->min_fee != $min_fee) {
                    $bad_height = $block->height;
                }
            }
            $prev_block = $block;
            last if defined($bad_height);
            Debugf("Block %d (%s) is valid", $block->height, $block->hash_str);
        }
        last if defined($bad_height);
        last if $block_count < $portion;
    }
    skip_scripts(0);
    undef $prev_block;
    if (!defined($bad_height)) {
        Infof("All stored blocks are valid");
        return;
    }
    Noticef("Blocks starting from height %d are invalid", $bad_height);
    # Remove all blocks starting from the bad block
    # It's safe to remove the loop with unconfirming transactions,
    # in this case they will not be saved in mempool (mb huge)
    # and will be requested from the neighbor nodes as on usual blockchain sync
    foreach my $tx_hashref ($tx_class->fetch( block_height => { '>=' => $bad_height }, -sortby => 'block_height DESC, block_pos DESC' )) {
        my $tx = $tx_class->get($tx_hashref->{hash});
        if (!$tx) {
            $tx_class->pre_load($tx_hashref);
            $tx = $tx_class->new($tx_hashref);
            if ($tx->validate_hash or $tx->validate) {
                foreach my $in (@{$tx->in}) {
                    $in->{txo}->spent_del($tx);
                }
                next;
            }
            $tx->add_to_cache;
        }
        $tx->received_time = time();
        $tx->unconfirm;
    }
    QBitcoin::Block->delete_by(height => { '>=' => $bad_height });
}

1;
