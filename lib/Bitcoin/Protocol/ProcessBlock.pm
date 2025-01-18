package Bitcoin::Protocol::ProcessBlock;
use warnings;
use strict;
use feature 'state';

use Role::Tiny;
use List::Util qw(max);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::ProtocolState qw(btc_synced);
use QBitcoin::ConnectionList;
use QBitcoin::Coinbase;
use Bitcoin::Block;

# these values shared between QBitcoin::Protocol and Bitcoin::Protocol, they are related to btc blockchain, not to protocol
sub have_block0 :lvalue {
    my $self = shift;
    state $have_block0 = Bitcoin::Block->find(height => 0) ? 1 : 0;
    $have_block0 = $_[0] if @_;
    return $have_block0;
}

sub process_btc_block {
    my $self = shift;
    my ($block) = @_;

    state $LAST_BLOCK;
    state $CHAINWORK;
    # https://bitcoin.stackexchange.com/questions/26869/what-is-chainwork
    my $chainwork = $block->difficulty * 4295032833; # it's 0x0100010001, avoid perl warning about too large hex number
    if ($block->prev_hash eq ZERO_HASH) {
        if ($block->genesis_hash && $block->genesis_hash ne $block->hash) {
            Warningf("Genesis block hash mismatch, expected %s, got %s", $block->genesis_hash_hex, $block->hash_hex);
            return undef;
        }
        $block->height = 0;
        $CHAINWORK = $block->chainwork = $chainwork;
    }
    else {
        my $prev_block;
        $prev_block = $LAST_BLOCK if $LAST_BLOCK && $LAST_BLOCK->hash eq $block->prev_hash;
        $prev_block //= Bitcoin::Block->find(hash => $block->prev_hash);
        if ($prev_block) {
            if (!$config->{ecr_testnet}) {
                # check difficulty, it should not be less than max(last N blocks)/4 for mainnet
                # it's only for prevent spam by many blocks with small difficulty
                my $prev_difficulty = max map { $_->difficulty } $prev_block, Bitcoin::Block->find(hash => $prev_block->prev_hash);
                if ($block->difficulty < $prev_difficulty / 4.001) {
                    Warningf("Too low difficulty for block %s, ignore it", $block->hash_hex);
                    return undef;
                }
            }
            $block->chainwork = $prev_block->chainwork + $chainwork;
            $CHAINWORK //= (map { $_->chainwork } Bitcoin::Block->find(height => { "IS NOT " => undef }, -sortby => 'height DESC', -limit => 1))[0];
            if ($block->chainwork > $CHAINWORK) {
                my $start_block = $prev_block;
                my $new_height = 1;
                while (!defined $start_block->height) {
                    $start_block = Bitcoin::Block->find(hash => $start_block->prev_hash)
                        or die "Bitcoin blockchain consistensy broken\n";
                    $new_height++;
                }
                my $revert_height;
                foreach my $revert_block (Bitcoin::Block->find(height => { '>' => $start_block->height }, -sortby => 'height DESC')) {
                    if (!$revert_height) {
                        $revert_height = $revert_block->height;
                        Noticef("Revert blockchain height %u-%u", $start_block->height+1, $revert_height);
                        # Explicitly delete coinbase b/c "on delete cascade" doesn't work for update reference key
                        # TODO: rollback QBT blocks if reverted blocks contain generated QBT coinbase
                        QBitcoin::Coinbase->delete_by(btc_block_height => { '>' => $start_block->height });
                    }
                    $revert_block->update(height => undef);
                }
                $block->height = $start_block->height + $new_height--;
                my @new_blocks;
                for (my $cur_block = $prev_block; !defined $cur_block->height;) {
                    $cur_block->update(height => $start_block->height + $new_height--);
                    push @new_blocks, $cur_block;
                    $cur_block = Bitcoin::Block->find(hash => $cur_block->prev_hash)
                        or die "Can't find prev block, check bitcoin blockchain consistensy\n";
                }
                $CHAINWORK = $block->chainwork;
                foreach my $new_block (reverse @new_blocks) {
                    $self->announce_btc_block_to_peers($new_block);
                }
            }
        }
        else {
            Warningf("Received orphan block %s, prev hash %s", $block->hash_hex, $block->prev_hash_hex);
            if ($self->have_block0 && !$self->syncing) {
                $self->request_btc_blocks();
            }
            return undef;
        }
    }
    if (defined $block->height) {
        $LAST_BLOCK = $block;
        $self->announce_btc_block_to_peers($block);
    }
    return $block;
}

sub announce_btc_block_to_peers {
    my $self = shift;
    my ($block) = @_;

    if (btc_synced()) {
        foreach my $connection (QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN)) {
            next if $connection->peer->id eq $self->peer->id && $self->type_id == PROTOCOL_QBITCOIN;
            next unless $connection->protocol->can('announce_btc_block');
            $connection->protocol->announce_btc_block($block);
        }
    }
}

1;
