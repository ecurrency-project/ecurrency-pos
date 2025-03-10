package QBitcoin::Protocol;
use warnings;
use strict;

# TCP exchange with a peer
# Single connection
# Commands:
# >> version <options>
# << verack <options>
# >> ihave <time> <weight> <hash>
# << sendblock <hash>
# >> block <size>
# >> ...
# >> end

# First "ihave" with the best existing time/weight send directly after connection from both sides

# >> ihavetx <txid> <size> <fee>
# << sendtx <txid>
# >> tx <size>
# >> ...

# << mempool
# >> ihavetx <txid> <size> <fee>
# >> ...
# >> eomempool

# Send "mempool" to the first connected node after start, then (after get it) switch to "synced" mode

# >> ping <payload>
# << pong <payload>
# Use "ping emempool" -> "pong emempool" for set mempool_synced state, this means all mempool transactions requested and sent

# If our last known block height less than height_by_time, then batch request all blocks with height from last known to max available

use parent 'QBitcoin::Protocol::Common';
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced btc_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::Peer;
use Bitcoin::Serialized;

use Role::Tiny::With;
with 'QBitcoin::Protocol::BTC' if UPGRADE_POW;

use constant {
    MAGIC             => "QBTC",
    MAGIC_TESTNET     => "QBTT",
    PROTOCOL_VERSION  => 1,
    PROTOCOL_FEATURES => 0,
};

use constant {
    REJECT_INVALID => 1,
};

mk_accessors(qw(has_weight has_time));

sub type_id() { PROTOCOL_QBITCOIN }

sub startup {
    my $self = shift;
    my $version = pack("VQ<Q<a26", PROTOCOL_VERSION, PROTOCOL_FEATURES, time(), $self->pack_my_address);
    $self->send_message("version", $version);
    return 0;
}

sub pack_my_address {
    my $self = shift;
    return pack("Q<a16n", PROTOCOL_FEATURES, $self->connection->my_addr, $self->connection->my_port);
}

sub peer_id {
    my $self = shift;
    return $self->{peer_id} //= $self->peer->ip;
}

sub cmd_version {
    my $self = shift;

    $self->send_message("verack", "");
    $self->greeted = 1;
    $self->request_btc_blocks() if UPGRADE_POW && !btc_synced();
    $self->request_mempool if blockchain_synced() && !mempool_synced() && (!UPGRADE_POW || btc_synced());
    $self->announce_best_btc_block() if UPGRADE_POW;
    if (my $best_block = QBitcoin::Block->best_block) {
        $self->announce_block($best_block);
    }
    return 0;
}

sub cmd_verack {
    my $self = shift;
    return 0;
}

sub request_tx {
    my $self = shift;
    $self->send_message("sendtx", $_) foreach @_;
}

sub announce_tx {
    my $self = shift;
    my ($tx) = @_;
    $self->send_message("ihavetx", $tx->hash);
}

sub request_mempool {
    my $self = shift;
    $self->send_message("mempool", "");
}

sub abort {
    my $self = shift;
    my ($reason) = @_;
    $self->send_message("reject", pack("C/a*", $self->command) . pack("C", REJECT_INVALID) . pack("C/a*", $reason // "general_error"));
    $self->peer->decrease_reputation;
}

sub announce_block {
    my $self = shift;
    my ($block) = @_;
    $self->send_message("ihave", pack("VQ<a32", $block->time, $block->weight, $block->hash));
}

sub cmd_sendtx {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 32) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my $hash = unpack("a32", $data); # yes, it's copy of $data
    my $tx = QBitcoin::Transaction->get_by_hash($hash);
    if ($tx) {
        $self->send_message("tx", $tx->serialize . ($tx->received_from ? $tx->received_from->peer->ip : "\x00"x16));
    }
    else {
        Warningf("I have no transaction with hash %u requested by peer %s", $hash, $self->peer->id);
    }
    return 0;
}

sub cmd_ihavetx {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 32) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    blockchain_synced()
        or return 0;

    my $hash = unpack("a32", $data);
    if (QBitcoin::Transaction->check_by_hash($hash)) {
        return 0;
    }
    $self->request_tx($hash);
    return 0;
}

sub cmd_block {
    my $self = shift;
    my ($block_data) = @_;
    my $data = Bitcoin::Serialized->new($block_data);
    my $block = QBitcoin::Block->deserialize($data);
    if (!$block || $data->length) {
        Warningf("Bad block data length %u from peer %s", length($block_data), $self->peer->id);
        $self->abort("bad_block_data");
        return -1;
    }
    if (QBitcoin::Block->block_pool($block->hash)) {
        Debugf("Received block %s already in block_pool", $block->hash_str);
        $self->syncing(0);
        $self->request_new_block();
        return 0;
    }
    if ($block->is_pending) {
        Debugf("Received block %s already pending, skip", $block->hash_str);
        # $self->syncing(0);
        # TODO: request block if pending block; request tx if pending tx
        # TODO: Request pending block or transaction by chain
        # $self->request_new_block($block->prev_hash);
        return 0;
    }
    if ($block->time < (QBitcoin::Block->blockchain_time // -1)) {
        if (my $loaded_block = QBitcoin::Block->find(hash => $block->hash)) {
            Debugf("Received block %s height %u already known, skip", $block->hash_str, $loaded_block->height);
            $self->syncing(0);
            $self->request_new_block();
            return 0;
        }
    }

    $block->received_from = $self;
    $self->has_weight = $block->weight if ($self->has_weight // -1) < $block->weight;

    if (!$block->prev_hash) {
        $block->height = 0;
    }
    elsif (!$block->prev_block_load) {
        if (QBitcoin::Block->is_pending($block->prev_hash)) {
            Debugf("Received block %s has pending ancestor %s",
                $block->hash_str, $block->hash_str($block->prev_hash));
            $block->load_transactions();
            $self->request_tx($block->pending_tx);
            $block->add_pending_block();
            # TODO: request pending block or transaction
            return 0;
        }
        else {
            Debugf("Received block %s has unknown ancestor %s, request it",
                $block->hash_str, $block->hash_str($block->prev_hash));
            if ($block->pending_descendants || !blockchain_synced()) {
                # deep rollback, request batch of new blocks using locators
                $self->request_blocks(timeslot($block->time)-1);
            }
            else {
                $block->load_transactions();
                $self->request_tx($block->pending_tx);
                $self->send_message("sendblock", $block->prev_hash);
                $block->add_pending_block();
            }
            $self->syncing(1);
            return 0;
        }
    }

    $block->load_transactions();
    $self->syncing(0);
    if ($block->pending_tx) {
        $block->add_as_descendant();
        $self->request_tx($block->pending_tx);
    }
    else {
        $block->compact_tx();
        if ($block->receive() == 0) {
            $block = $block->process_pending();
            $self->request_new_block();
            return 0;
        }
        else {
            $block->drop_pending();
            return -1;
        }
    }
    return 0;
}

# Almost same as "block", but batch of blocks, and do not request next block after each processed
sub cmd_blocks {
    my $self = shift;
    my ($blocks_data) = @_;
    if (length($blocks_data) == 0) {
        Warningf("Bad (empty) blocks params from peer %s", $self->peer->id);
        $self->abort("incorrect_params");
        return -1;
    }
    my $data = Bitcoin::Serialized->new($blocks_data);
    my $num_blocks = unpack("C", $data->get(1));
    my $block;
    my $got_new;
    foreach my $num (1 .. $num_blocks) {
        my $prev_block = $block;
        $block = QBitcoin::Block->deserialize($data);
        if (!$block) {
            Warningf("Bad blocks data length from peer %s", $self->peer->id);
            $self->abort("bad_block_data");
            return -1;
        }
        Infof("Receive %u blocks started from %s time %u", $num_blocks, $block->hash_str, $block->time) if $num == 1;
        if (my $loaded_block = QBitcoin::Block->block_pool($block->hash)) {
            Debugf("Received block %s height %u already in block_pool, skip", $block->hash_str, $loaded_block->height);
            next;
        }
        if ($block->is_pending) {
            Debugf("Received block %s already pending, skip", $block->hash_str);
            last;
        }
        if ($block->time < (QBitcoin::Block->blockchain_time // 0)) {
            if (my $loaded_block = QBitcoin::Block->find(hash => $block->hash)) {
                Debugf("Received block %s height %u already known, skip", $block->hash_str, $loaded_block->height);
                next;
            }
        }

        $block->received_from = $self;
        $self->has_weight = $block->weight if ($self->has_weight // -1) < $block->weight;

        if ($num > 1) {
            if ($block->prev_hash ne $prev_block->hash) {
                Warningf("Received blocks are not in chain from peer %s", $self->peer->id);
                $self->abort("bad_block_data");
                return -1;
            }
            if (!$block->prev_block_load) {
                # some of ancestor blocks are pending tx?
                $block->load_transactions();
                $self->request_tx($block->pending_tx);
                $block->add_pending_block();
                $got_new++;
                next;
            }
        }
        elsif ($block->prev_hash && !$block->prev_block_load) {
            if (QBitcoin::Block->is_pending($block->prev_hash)) {
                Debugf("Received block %s has pending ancestor %s",
                    $block->hash_str, $block->hash_str($block->prev_hash));
                $block->load_transactions();
                $self->request_tx($block->pending_tx);
                $block->add_pending_block();
                next;
            }
            else {
                Debugf("Received block %s has unknown ancestor %s, request it",
                    $block->hash_str, $block->hash_str($block->prev_hash));
                $self->request_blocks(timeslot($block->time)-1);
                $self->syncing(1);
                return 0;
            }
        }

        $block->load_transactions();
        if ($block->pending_tx) {
            $self->request_tx($block->pending_tx);
            $block->add_as_descendant();
        }
        else {
            $block->compact_tx();
            if ($block->receive() == 0) {
                $block = $block->process_pending();
            }
            else {
                $block->drop_pending();
                return -1;
            }
        }
        $got_new++;
    }
    $self->syncing(0);
    # Do not request new blocks if we already have pending block
    if ($block && !$block->is_pending) {
        if ($got_new) {
            if ($num_blocks == BLOCKS_IN_BATCH && $block->time + FORCE_BLOCKS * BLOCK_INTERVAL < timeslot(time())) {
                $self->send_message("getblks", pack("Vv", timeslot($block->time), 1) . $block->hash);
                $self->syncing(1);
            }
            else {
                $self->request_new_block();
            }
        }
        elsif ($block->time < $self->has_time) {
            $self->send_message("getblks", pack("Vv", 0, 1) . $block->hash);
        }
    }
    return 0;
}

sub cmd_tx {
    my $self = shift;
    my ($tx_data) = @_;
    my $data = Bitcoin::Serialized->new($tx_data);
    my $tx = QBitcoin::Transaction->deserialize($data);
    if (!$tx || $data->length != 16) {
        Warningf("tx %s deserialization error, data length %u", $tx ? $tx->hash_str : "undef", $data->length);
        $self->abort("bad_tx_data");
        return -1;
    }
    if (QBitcoin::Transaction->has_pending($tx->hash)) {
        Debugf("Transaction %s already pending", $tx->hash_str);
        return 0;
    }
    if (QBitcoin::Transaction->check_by_hash($tx->hash)) {
        Debugf("Transaction %s already known", $tx->hash_str);
        return 0;
    }
    $tx->rcvd = $data->get(16);
    $tx->received_from = $self;
    if (!$tx->load_txo()) {
        $self->abort("bad_tx_data");
        return -1;
    }
    if ($tx->is_pending) {
        return 0;
    }
    if ($self->process_tx($tx) == -1) {
        return -1;
    }
    return 0;
}

sub process_tx {
    my $self = shift;
    my ($tx) = @_;

    if ($tx->receive() != 0) {
        $self->abort("bad_tx_data");
        return -1;
    }
    if (defined(my $height = QBitcoin::Block->recv_pending_tx($tx))) {
        return -1 if $height == -1;
        # We've got new block on receive this tx, so we should request new blocks as after usual block receiving
        # It may be the way for set blockchain_synced(1) if it was the best block
        # But it can produce many unneeded "sendblock" or "getblks" requests, see comment in request_new_block() about it
        $self->syncing(0);
        $self->request_new_block();
    }
    if ($tx->fee >= 0) {
        if (blockchain_synced() && mempool_synced()) {
            # announce to other peers
            $tx->announce();
            if ($tx->fee > 0 || $tx->up) {
                my $recv_peer = $tx->received_from && $tx->received_from->can('peer') ? $tx->received_from->peer : undef;
                if ($recv_peer) {
                    $recv_peer->add_reputation($tx->up ? 200 : 2);
                }
                if ($tx->rcvd && $tx->rcvd ne "\x00"x16 && (!$recv_peer || $recv_peer->ip ne $tx->rcvd)) {
                    my $src_peer = QBitcoin::Peer->get_or_create(type_id => PROTOCOL_QBITCOIN, ip => $tx->rcvd);
                    $src_peer->add_reputation($tx->up ? 100 : 1) if $src_peer;
                }
            }
        }
    }
    return 0;
}

sub request_new_block {
    my $self = shift;
    my ($hash) = @_;

    if (!$self->syncing) {
        my $best_time = QBitcoin::Block->blockchain_time // 0;
        my $best_block = QBitcoin::Block->best_block;
        my $best_weight = $best_block ? $best_block->weight : -1;
        # Do not request block(s) if we have block pending for tx with more weight from the same peer,
        # simple set $self->syncing(1) in this case to avoid many unneeded blocks requests in initial synchronization
        if ($best_block && !$hash) {
            foreach my $descendant ($best_block->descendants) {
                if ($descendant->received_from && $descendant->received_from->peer->id eq $self->peer->id) {
                    $self->syncing(1);
                    return;
                }
            }
        }
        if (($self->has_weight // -1) > $best_weight ||
            (($self->has_weight // -1) == $best_weight && timeslot($self->has_time // 0) > timeslot($best_time))) {
            # Should we request batch blocks if $self->has_weight == $best_weight?
            # If yes, it's possible to request the same batch in infinite loop when remote has no new blocks
            # If no, we will request long chain of empty blocks one-by-one
            # It seems we should not request_new_block after receiving batch without any new block
            if (timeslot($self->has_time // 0) > timeslot($best_time) + BLOCK_INTERVAL || !blockchain_synced()) {
                $self->request_blocks();
                $self->syncing(1);
            }
            else {
                if (($self->has_weight // -1) > $best_weight) { # otherwise remote may have no such block, no syncing
                    $self->syncing(1);
                    Debugf("Remote %s has block weight %Lu more than our %Lu, request block", $self->peer->id, $self->has_weight, $best_weight);
                }
                $self->send_message("sendblock", $hash // ZERO_HASH);
            }
        }
        elsif (!blockchain_synced() && $best_block) {
            if (timeslot($best_block->time) + FORCE_BLOCKS * BLOCK_INTERVAL >= timeslot(time())) {
                Infof("Blockchain is synced");
                blockchain_synced(1);
                if (!mempool_synced()) {
                    $self->request_mempool();
                }
            }
        }
    }
}

# Request batch of blocks using locators (hashes of our blocks in the best branch)
sub request_blocks {
    my $self = shift;
    my ($top_time) = @_;
    my $low_time = $top_time // 0;
    $top_time ||= time();
    my @blocks;
    for (my $height = QBitcoin::Block->blockchain_height // -1; $height >= 0; $height--) {
        last if $height <= QBitcoin::Block->blockchain_height - INCORE_LEVELS;
        my $best_block = QBitcoin::Block->best_block($height)
            or last;
        if ($best_block->time <= $top_time) {
            push @blocks, $best_block;
            last if @blocks >= 10;
        }
    }
    if (@blocks < 10) {
        push @blocks, QBitcoin::Block->find(time => { '<=' => $top_time }, -sortby => 'height DESC', -limit => 10 - @blocks);
    }
    my @locators = map { $_->hash } @blocks;
    if (@locators) {
        $low_time = timeslot($blocks[-1]->time)-1;
        my $top_height = $blocks[0]->height;
        my $low_height = $blocks[-1]->height;
        my $step = 4;
        my $height = $blocks[-1]->height - $step;
        my @height;
        while ($height > 0 && @height < 32) {
            push @height, $height;
            $step *= 2;
            $step = BLOCK_LOCATOR_INTERVAL if $step > BLOCK_LOCATOR_INTERVAL;
            $height -= $step;
        };
        push @height, 0 if @height < 32;
        @blocks = QBitcoin::Block->find(-sortby => 'height DESC', height => \@height);
        if (@blocks) {
            push @locators, map { $_->hash } @blocks;
            $low_time = timeslot($blocks[-1]->time)-1;
            $low_height = $blocks[-1]->height;
        }
        Debugf("Request batch blocks before time %u, locators height %u .. %u", $low_time, $low_height, $top_height);
    }
    else {
        Debugf("Request batch blocks before time %u", $low_time);
    }
    $self->send_message("getblks", pack("Vv", $low_time, scalar(@locators)) . join("", @locators));
}

sub cmd_getblks {
    my $self = shift;
    my ($data) = @_;
    my $datalen = length($data);
    if ($datalen < 6) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my ($low_time, $locators) = unpack("Vv", substr($data, 0, 6));
    if ($datalen != 6+32*$locators) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my %locators = map { substr($data, 6+$_*32, 32) => 1 } 0 .. $locators-1;
    # Loop by incore levels is not good but better than loop by locators
    my $height;
    my $min_incore_height = QBitcoin::Block->min_incore_height;
    for ($height = QBitcoin::Block->blockchain_height; $height >= $min_incore_height; $height--) {
        my $block = QBitcoin::Block->best_block($height);
        if (!$block) {
            $height = -1;
            last;
        }
        last if $locators{$block->hash};
    }
    my $sent = 0;
    my $response = "";
    if ($height < $min_incore_height) {
        # No matched blocks in memory pool, search by database
        my ($block) = QBitcoin::Block->find(hash => [ keys %locators ], -sortby => 'height DESC', -limit => 1);
        if ($block) {
            $height = $block->height;
        }
        else {
            my @blocks;
            if ($low_time) {
                # No block for any locator found, send two blocks: one just before $low_time and one just after
                # for cover cases if prev block already exists on remote and if next our block is too far in future
                my $new_block;
                for ($height = QBitcoin::Block->blockchain_height; $height >= $min_incore_height; $height--) {
                    my $prev_block = QBitcoin::Block->best_block($height)
                        or last;
                    if ($prev_block->time <= $low_time) {
                        $block = $prev_block;
                        last;
                    }
                    $new_block = $prev_block;
                }
                if (!$block) {
                    $block = QBitcoin::Block->find(time => { '<=' => $low_time }, -sortby => 'height DESC', -limit => 1);
                    if (!$new_block || !$block || $new_block->height != $block->height+1) {
                        $new_block = QBitcoin::Block->find(time => { '>' => $low_time }, -sortby => 'height ASC', -limit => 1);
                    }
                }
                push @blocks, $block if $block;
                push @blocks, $new_block if $new_block;
            }
            else {
                # special case
                $block = QBitcoin::Block->best_block;
                push @blocks, $block if $block;
            }
            if (@blocks == 1) {
                Debugf("No block for any locator found, send block height %u to %s",
                    $blocks[0]->height, $self->peer->id);
                $self->send_message("block", $blocks[0]->serialize);
            }
            elsif (@blocks) {
                Debugf("No block for any locator found, send blocks height %u .. %u to %s",
                    $blocks[0]->height, $blocks[-1]->height, $self->peer->id);
                $self->send_message("blocks", pack("C", scalar(@blocks)) . join('', map { $_->serialize } @blocks));
            }
            else {
                Warningf("I have no block with height %d requested by peer %s", $height, $self->peer->id);
            }
            return 0;
        }
        foreach my $block (QBitcoin::Block->find(height => { '>' => $height }, -sortby => 'height ASC', -limit => BLOCKS_IN_BATCH)) {
            $response .= $block->serialize;
            $height = $block->height;
            $sent++;
        }
    }
    my $max_height = QBitcoin::Block->blockchain_height;
    while ($height++ < $max_height && $sent < BLOCKS_IN_BATCH) {
        my $block = QBitcoin::Block->best_block($height);
        if ($block) {
            $response .= $block->serialize;
            $sent++;
        }
        else {
            Warningf("Can't find best block height %u", $height--);
            last;
        }
    }
    if ($sent) {
        Infof("Send blocks height %u .. %u to %s", $height-$sent, $height-1, $self->peer->id);
        $self->send_message("blocks", pack("C", $sent) . $response);
    }
    return 0;
}

sub cmd_ihave {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 44) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my ($time, $weight, $hash) = unpack("VQ<a32", $data);
    if (time() < timeslot($time)) {
        Warningf("Ignore too early block time %u from peer %s", $time, $self->peer->id);
        return 0;
    }
    if ($weight < ($self->has_weight // -1)) {
        Warningf("Remote %s decreases weight %Lu => %Lu", $self->has_weight, $weight);
        $self->syncing(0); # prevent blocking connection on infinite wait
    }
    $self->has_weight = $weight;
    $self->has_time = $time;
    if (!UPGRADE_POW || btc_synced()) {
        if ($weight > QBitcoin::Block->best_weight ||
            ($weight == QBitcoin::Block->best_weight && timeslot($time) > QBitcoin::Block->blockchain_time)) {
            if (!QBitcoin::Block->block_pool($hash) && !QBitcoin::Block->is_pending($hash)) {
                $self->request_new_block($hash);
            }
        }
    }
    return 0;
}

sub cmd_sendblock {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 32) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my $hash = $data;
    my $block;
    if ($hash eq ZERO_HASH) {
        $block = QBitcoin::Block->best_block;
    }
    else {
        $block = QBitcoin::Block->block_pool($hash) // QBitcoin::Block->find(hash => $hash);
        if (!$block) {
            Debugf("I have no block with requested hash %s, send best instead", QBitcoin::Block->hash_str($hash));
            $block = QBitcoin::Block->best_block;
        }
    }
    if ($block) {
        $self->send_message("block", $block->serialize);
    }
    else {
        Infof("I have no best block, ignore sendblock request");
    }
    return 0;
}

sub cmd_mempool {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 0) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    foreach my $tx (QBitcoin::Transaction->mempool_list) {
        $self->announce_tx($tx);
    }
    $self->send_message("eomempool", "");
    return 0;
}

sub cmd_eomempool {
    my $self = shift;
    my $data = shift;
     if (length($data) != 0) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    $self->send_message("ping", pack("a8", "emempool"));
    $self->ping_sent = time();
    return 0;
}

sub cmd_ping {
    my $self = shift;
    my ($data) = @_;
    $self->send_message("pong", $data);
    return 0;
}

sub drop_pending {
    my $self = shift;
    QBitcoin::Block->drop_all_pending($self);
    QBitcoin::Transaction->drop_all_pending($self);
}

sub cmd_pong {
    my $self = shift;
    my ($data) = @_;
    if ($data eq "emempool") {
        mempool_synced(1);
        Infof("Mempool is synced, %u transactions", scalar QBitcoin::Transaction->mempool_list());
    }
    if ($self->last_cmd_ping && $data eq pack("Q", $self->last_cmd_ping)) {
        # There were no received messages since last our "ping" sent, so it's not syncing state
        if ($self->syncing) {
            Infof("%s peer %s is in syncing state but no data receiving, reset syncing", $self->type, $self->peer->id);
            $self->syncing(0);
            $self->drop_pending();
        }
    }
    $self->last_cmd_ping = undef;
    return 0;
}

sub cmd_reject {
    my $self = shift;
    Warningf("%s peer %s aborted connection", $self->type, $self->peer->id);
    return -1;
}

sub keepalive {
    my $self = shift;
    my $time = time();
    if (!$self->ping_sent) {
        # Do not send ping directly after connect
        $self->ping_sent = $time;
    }
    elsif ($self->last_cmd_ping) {
        if ($self->ping_sent + PEER_RECV_TIMEOUT < $time) {
            # Timeout: no response for ping and no other commands received since ping was sent
            return 0;
        }
    }
    elsif ($self->ping_sent + PEER_PING_PERIOD < $time) {
        # Send "ping" after each PEER_PING_PERIOD seconds even if there are other commands received from the peer
        # This needed to reset "syncing" state in case when remote periodically announce new blocks or transactions, or just "ping" us
        # Bitcoin node can ignore "getheaders" if it is in "initial block download" state,
        # and in this case protocol will remain in "syncing" state and do not request new blocks until "ping" response and reset "syncing"
        $self->send_message("ping", pack("Q", $time));
        $self->ping_sent = $time;
        $self->last_cmd_ping = $time;
    }
    return 1;
}

1;
