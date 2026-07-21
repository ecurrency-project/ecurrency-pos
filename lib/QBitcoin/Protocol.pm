package QBitcoin::Protocol;
use warnings;
use strict;

# TCP exchange with a peer
# Single connection
# Commands:
# >> version <version:4 features:8 time:8 my_address:26 nonce:8 software:1+n>
#    my_address: features:8 addr:16 port:2 (port is the node's listening port, to dial it back
#    and to announce it to other peers; 0 means the node does not accept incoming connections)
#    nonce: random session id, used to detect duplicate connections with the same node
#    software: 1-byte length + string, name and version of the node software (see SOFTWARE, as BIP14)
#    nonce and software are optional (old nodes do not send them), unknown trailing data must be ignored
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

# >> getaddr
# << addr <count> <ip:16 port:2> ...  (peer address exchange)

# << vernak <count> <ip:16 port:2> ...  (rejection with peer list, sent instead of verack when at capacity)

# If our last known block height less than height_by_time, then batch request all blocks with height from last known to max available

use parent 'QBitcoin::Protocol::Common';
use Time::HiRes;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced btc_synced sync_peer last_qbt_data_time);
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Peer;
use QBitcoin::Generate::Control;
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

mk_accessors(qw(has_weight best_block_hash reject_with_peers protocol_version remote_nonce));

sub type_id() { PROTOCOL_QBITCOIN }

# Random identifier of this node instance, sent in the "version" message.
# It identifies the remote node better than the IP address: several nodes may share
# one NAT address, and one node may be reachable via different addresses.
# Used to detect duplicate connections with the same node, including self-connections.
my $MY_NONCE;
sub my_nonce {
    return $MY_NONCE //= pack("VV", int(rand(2**32)), int(rand(2**32)));
}

sub startup {
    my $self = shift;
    my $version = pack("VQ<Q<a26a8C/a*", PROTOCOL_VERSION, PROTOCOL_FEATURES, time(), $self->pack_my_address, my_nonce(), SOFTWARE);
    $self->send_message("version", $version);
    return 0;
}

# The port on which this node accepts incoming connections, advertised to peers in the
# "version" message so they can dial us back; must match bind_addr() in QBitcoin::Network
sub listen_port {
    my (undef, $port) = split(/:/, $config->{bind} // BIND_ADDR);
    return $port // $config->{port} // getservbyname(SERVICE_NAME, 'tcp') // PORT;
}

sub pack_my_address {
    my $self = shift;
    # not connection->my_port: for outgoing connections it is the ephemeral port of the socket,
    # the peer needs our listening port.
    # In pinned-only mode advertise port 0 ("does not accept incoming connections"): the remote
    # then neither stores nor announces us (see cmd_version), keeping a hidden node unlisted.
    my $port = $config->{pinned_only} ? 0 : listen_port();
    return pack("Q<a16n", PROTOCOL_FEATURES, $self->connection->my_addr, $port);
}

sub peer_id {
    my $self = shift;
    return $self->{peer_id} //= $self->peer->ip;
}

sub cmd_version {
    my $self = shift;

    if ($self->reject_with_peers) {
        $self->send_vernak();
        return -1;
    }

    my ($data) = @_;
    if (length($data) < 20) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my ($protocol_version, $protocol_features, $remote_time) = unpack("VQ<Q<", $data);
    # The peer advertises its own listening address (see pack_my_address): features(8) addr(16) port(2).
    # We need the advertised port to know the peer's real service port (especially for incoming connections).
    my $adv_port;
    if (length($data) >= 20 + 26) {
        (undef, undef, $adv_port) = unpack("Q<a16n", substr($data, 20, 26));
    }
    # Optional trailing session nonce (see my_nonce); old nodes do not send it and ignore these bytes
    my $nonce;
    if (length($data) >= 20 + 26 + 8) {
        $nonce = substr($data, 20 + 26, 8);
    }
    # Optional software name and version (see SOFTWARE), 1-byte length + string after the nonce
    my $software;
    if (length($data) >= 20 + 26 + 8 + 1) {
        my $len = unpack("C", substr($data, 54, 1));
        if (length($data) >= 55 + $len) {
            $software = substr($data, 55, $len);
            # the string is written to logs and to the database, keep only printable ascii
            $software =~ tr/\x20-\x7e//cd;
        }
    }
    if ($self->check_duplicate_connection($nonce) != 0) {
        return -1;
    }
    $self->remote_nonce = $nonce;

    $self->send_message("verack", "");
    $self->greeted = 1;
    $self->protocol_version = $protocol_version;
    if ($self->connection->direction == DIR_OUT) {
        # We reached this peer ourselves: it is confirmed reachable / accepts incoming connections.
        $self->peer->connect_success();
    }
    else {
        # Incoming connection: store the peer now that the greeting succeeded (req: do not persist random connects).
        # The advertised port is trusted only when the session nonce is present: older nodes mistakenly
        # advertise the ephemeral port of their outgoing socket instead of their listening port,
        # for them keep the default port (a reachability probe will verify it before announcing).
        my $adv_port_trusted = defined($nonce) ? $adv_port : undef;
        if (defined($adv_port_trusted) && !$adv_port_trusted) {
            # The peer explicitly advertises port 0: it does not accept incoming connections,
            # do not store it - useless for dial-back and for announcing to other peers
        }
        else {
            my $peer = $self->peer->persist();
            if ($peer != $self->peer) {
                $self->peer($peer);
                $self->connection->peer($peer);
            }
            $peer->update(port => $adv_port_trusted) if $adv_port_trusted && $peer->port != $adv_port_trusted;
        }
    }
    Infof("Peer %s greeted: version %u, features 0x%x, software %s",
        $self->peer->id, $protocol_version, $protocol_features, $software // "unknown");
    if (defined($software) && ($self->peer->software // "") ne $software) {
        $self->peer->update(software => $software);
    }
    $self->request_btc_blocks() if UPGRADE_POW && !UPGRADE_FINISHED && !btc_synced();
    $self->request_mempool if blockchain_synced() && !mempool_synced() && (!UPGRADE_POW || btc_synced());
    $self->announce_best_btc_block() if UPGRADE_POW && !UPGRADE_FINISHED;
    if (my $best_block = QBitcoin::Block->best_block) {
        $self->announce_block($best_block);
    }
    $self->request_peer_addresses;
    return 0;
}

sub cmd_verack {
    my $self = shift;
    $self->request_peer_addresses;
    return 0;
}

# Request peer addresses if we don't have enough peers;
# useless in pinned-only mode where learned peers are never dialed
sub request_peer_addresses {
    my $self = shift;
    return if $config->{pinned_only};
    my @known_peers = grep { $_->reputation > 0 } QBitcoin::Peer->get_all(PROTOCOL_QBITCOIN);
    if (@known_peers < MIN_CONNECTIONS * 2) {
        $self->send_message("getaddr", "");
    }
}

# Drop duplicate connections with the same remote node: simultaneous mutual connects,
# or a reconnect while the old (dead) session has not timed out yet.
# The node is identified by the session nonce from the "version" message rather than by IP address:
# different nodes behind one NAT address have the same IP, so the IP identifies the node
# only among old peers which do not send the nonce.
# Returns 0 if this connection is unique (or wins the tie-break), -1 if it must be closed.
sub check_duplicate_connection {
    my $self = shift;
    my ($nonce) = @_;
    my $connection = $self->connection;
    if (defined $nonce) {
        if ($nonce eq my_nonce()) {
            Warningf("Connection with myself via %s, closing", $self->peer->id);
            # no "nocall" status for the peer: another node may be reachable via the same (NAT) address
            return -1;
        }
        foreach my $other (grep { $_ != $connection && $_->type_id == $self->type_id } QBitcoin::ConnectionList->list()) {
            $other->protocol && defined($other->protocol->remote_nonce) && $other->protocol->remote_nonce eq $nonce
                or next;
            my $drop_this;
            if ($connection->probe || $other->probe) {
                # a reachability probe must never displace a working connection
                $drop_this = $connection->probe;
            }
            elsif ($other->direction == $connection->direction) {
                # The remote node opened a new connection knowing nothing about the old one
                # (reconnect after silent disconnect, or dial via our different addresses),
                # so the old session is stale or will be dropped on the remote side; keep the new one
                $drop_this = 0;
            }
            else {
                # Simultaneous mutual connect; both sides must keep the same connection,
                # so the choice depends only on the nonces: the lesser nonce is the caller
                $drop_this = $connection->direction == (my_nonce() lt $nonce ? DIR_IN : DIR_OUT);
            }
            if ($drop_this) {
                Infof("Duplicate connection with peer %s, closing this one", $self->peer->id);
                # the handshake did succeed, closing a duplicate is not a failed connect
                $self->greeted = 1;
                $self->peer->connect_success() if $connection->direction == DIR_OUT;
                return -1;
            }
            Infof("Duplicate connection with peer %s, closing the old one", $self->peer->id);
            $other->disconnect();
        }
    }
    else {
        # The remote node sends no nonce (old version): assume single node per IP, as before,
        # but only among connections which did not prove otherwise by their nonce
        foreach my $other (grep { $_ != $connection && $_->type_id == $self->type_id } QBitcoin::ConnectionList->list()) {
            next unless $other->addr eq $connection->addr;
            next if $other->protocol && defined($other->protocol->remote_nonce); # a new node behind the same IP
            Warningf("Already connected with peer %s, closing duplicate connection", $self->peer->id);
            return -1;
        }
    }
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
        $self->send_message("tx", $tx->serialize . QBitcoin::Peer->announce_origin_ip($tx->received_from, $tx->rcvd));
        $self->connection->obj_sent++;
    }
    else {
        # Own stake tx which was already dropped?
        Debugf("I have no transaction with hash %s requested by peer %s", lc(unpack("H*", $hash)), $self->peer->id);
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
    $self->connection->obj_recv++;
    if (QBitcoin::Block->block_pool($block->hash)) {
        Debugf("Received block %s already in block_pool", $block->hash_str);
        $self->syncing(0);
        $self->request_new_block();
        return 0;
    }
    if ($block->is_pending) {
        Debugf("Received block %s already pending, continue from the pending chain bottom", $block->hash_str);
        $self->continue_pending_branch($block->hash);
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

    last_qbt_data_time(time());
    $block->received_from = $self;
    if (($self->has_weight // -1) < $block->weight) {
        $self->has_weight = $block->weight;
        $self->best_block_hash = $block->hash;
    }

    if (!$block->prev_hash) {
        $block->height = 0;
    }
    elsif (!$block->prev_block_load) {
        if (QBitcoin::Block->is_pending($block->prev_hash)) {
            Debugf("Received block %s has pending ancestor %s",
                $block->hash_str, $block->hash_str($block->prev_hash));
            $block->load_transactions();
            $block->add_pending_block();
            # Continue requesting the branch from the bottom of the pending chain
            $self->continue_pending_branch($block->prev_hash);
            return 0;
        }
        else {
            Debugf("Received block %s has unknown ancestor %s, request it",
                $block->hash_str, $block->hash_str($block->prev_hash));
            if (!blockchain_synced()) {
                # deep rollback, request batch of new blocks using locators
                $self->request_blocks(timeslot($block->time)-1);
            }
            else {
                # do not request pending transactions of the block here, see above
                $block->load_transactions();
                $self->send_message("sendblock", $block->prev_hash);
                $block->add_pending_block();
            }
            $self->syncing(1);
            return 0;
        }
    }

    $block->load_transactions();
    if ($block->pending_tx) {
        $block->add_as_descendant();
        $self->request_tx($block->pending_tx);
    }
    else {
        $self->syncing(0);
        $block->compact_tx();
        if ($block->receive() == 0) {
            $block = $block->process_pending($self);
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
        $self->connection->obj_recv++;
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

        last_qbt_data_time(time());
        $block->received_from = $self;
        if (($self->has_weight // -1) < $block->weight) {
            $self->has_weight = $block->weight;
            $self->best_block_hash = $block->hash;
        }

        if ($num > 1) {
            if ($block->prev_hash ne $prev_block->hash) {
                Warningf("Received blocks are not in chain from peer %s: block %s prev_hash %s prev block %s",
                    $self->peer->id, $block->hash_str, $block->hash_str($block->prev_hash), $prev_block->hash_str);
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
                my $last_block = $block->process_pending($self);
                $block = $last_block if $num == $num_blocks;
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
        elsif ($block->weight < $self->has_weight) {
            $self->send_message("getblks", pack("Vv", 0, 1) . $block->hash);
            $self->syncing(1);
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
    $self->connection->obj_recv++;
    if (QBitcoin::Transaction->has_pending($tx->hash)) {
        Debugf("Transaction %s already pending", $tx->hash_str);
        return 0;
    }
    if (QBitcoin::Transaction->check_by_hash($tx->hash)) {
        Debugf("Transaction %s already known", $tx->hash_str);
        return 0;
    }
    last_qbt_data_time(time());
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
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my $self = shift;
    my ($tx) = @_;

    my $rc = $tx->receive();
    if (!defined($rc)) {
        # Transaction rejected by mempool admission control, not invalid
        return 0;
    }
    if ($rc != 0) {
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
                my $recv_peer = $tx->received_from_peer ? $tx->received_from->peer : undef;
                if ($recv_peer) {
                    $recv_peer->add_reputation($tx->up ? 200 : 2);
                }
                if ($tx->rcvd && $tx->rcvd ne "\x00"x16 && (!$recv_peer || $recv_peer->ip ne $tx->rcvd)
                    && !$config->{pinned_only}) { # do not learn peers from the relayed origin in pinned-only mode
                    my $src_peer = QBitcoin::Peer->get_or_create(type_id => PROTOCOL_QBITCOIN, ip => $tx->rcvd);
                    $src_peer->add_reputation($tx->up ? 100 : 1) if $src_peer;
                }
                # Regenerate our block for the current timeslot to include this paid
                # transaction and claim its reward by staking, but only if the slot has
                # no block yet, or its block has no stake transaction (which can only be
                # the first one), or the best block was generated by us
                if (QBitcoin::TXO->staked_utxo) {
                    my $best = QBitcoin::Block->best_block;
                    if (!$best->received_from
                        || !@{$best->transactions} || !$best->transactions->[0]->is_stake) {
                        QBitcoin::Generate::Control->generate_new();
                    }
                }
            }
        }
    }
    return 0;
}

sub continue_pending_branch {
    my $self = shift;
    my ($hash) = @_;

    my $bottom = QBitcoin::Block->pending_block($hash)
        or return;
    while ($bottom->prev_hash) {
        my $prev_pending = QBitcoin::Block->pending_block($bottom->prev_hash)
            or last;
        $bottom = $prev_pending;
    }
    my $owner = $bottom->received_from;
    if ($owner && $owner != $self && $owner->connection && $owner->syncing) {
        # The branch is being downloaded via another peer, do not duplicate its requests
        $self->syncing(0);
        return;
    }
    $bottom->prev_hash
        or return;
    if ($bottom->pending_tx
        && (QBitcoin::Block->block_pool($bottom->prev_hash) || QBitcoin::Block->find(hash => $bottom->prev_hash))) {
        # The ancestor is already known, the bottom block waits only for its transactions
        $self->request_tx($bottom->pending_tx);
    }
    else {
        $self->send_message("sendblock", $bottom->prev_hash);
        $self->syncing(1);
    }
}

sub request_new_block {
    my $self = shift;
    my ($hash) = @_;

    if (!blockchain_synced() && sync_peer() && sync_peer() != $self) {
        return;
    }
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
        my $best_block_hash = $hash // $self->best_block_hash;
        if (($self->has_weight // -1) > $best_weight && !QBitcoin::Block->block_pool($best_block_hash) && !QBitcoin::Block->is_pending($best_block_hash)) {
            if (blockchain_synced()) {
                Debugf("Remote %s has block weight %Lu more than our %Lu, request block", $self->peer->id, $self->has_weight, $best_weight);
                $self->send_message("sendblock", $hash // ZERO_HASH);
            }
            else {
                $self->request_blocks();
            }
            $self->syncing(1);
        }
        elsif (!blockchain_synced() && $best_block) {
            if (timeslot($best_block->time) + FORCE_BLOCKS * BLOCK_INTERVAL >= timeslot(time())) {
                Infof("Blockchain is synced");
                blockchain_synced(1);
                last_qbt_data_time(time());
                sync_peer(undef);
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
    my $height = -1;
    my $min_incore_height = QBitcoin::Block->min_incore_height;
    my $blockchain_height = QBitcoin::Block->blockchain_height;
    if (%locators) {
        for ($height = $blockchain_height; $height >= $min_incore_height; $height--) {
            my $block = QBitcoin::Block->best_block($height);
            if (!$block) {
                $height = -1;
                last;
            }
            last if $locators{$block->hash};
        }
    }
    my $sent = 0;
    my $response = "";
    if ($height < $min_incore_height) {
        # No matched blocks in memory pool, search by database
        my $block;
        if (%locators) {
            ($block) = QBitcoin::Block->find(hash => [ keys %locators ], -sortby => 'height DESC', -limit => 1);
            $height = $block->height if $block;
        }
        if (!$block) {
            my @blocks;
            if ($low_time) {
                # No block for any locator found, send two blocks: one just before $low_time and one just after
                # for cover cases if prev block already exists on remote and if next our block is too far in future
                my $new_block;
                for ($height = $blockchain_height; $height >= $min_incore_height; $height--) {
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
                # special case: send genesis block
                $block = QBitcoin::Block->best_block(0) // QBitcoin::Block->find(height => 0);
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
    while ($height++ < $blockchain_height && $sent < BLOCKS_IN_BATCH) {
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
        $self->connection->obj_sent += $sent;
    }
    elsif (my $best_block = QBitcoin::Block->best_block) {
        # Nothing above the peer's locators: answer with our tip announce instead of
        # silence, so the requester refreshes our known weight and its sync-peer
        # timeout instead of timing out and re-requesting blindly.
        $self->announce_block($best_block);
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
        Warningf("Remote %s decreases weight %Lu => %Lu", $self->peer->id, $self->has_weight, $weight);
        $self->syncing(0); # prevent blocking connection on infinite wait
    }
    $self->has_weight = $weight;
    $self->best_block_hash = $hash;
    if (!UPGRADE_POW || btc_synced()) {
        if ($weight > QBitcoin::Block->best_weight) {
            if (blockchain_synced() || !sync_peer() || sync_peer() == $self) {
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
        $self->connection->obj_sent++;
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
    $self->ping_sent = Time::HiRes::time();
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
    return unless $self->has_pending;
    QBitcoin::Block->drop_all_pending($self);
    QBitcoin::Transaction->drop_all_pending($self);
    $self->has_pending(0);
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
        }
        $self->drop_pending();
    }
    $self->last_cmd_ping = undef;
    return 0;
}

sub cmd_reject {
    my $self = shift;
    Warningf("%s peer %s aborted connection", $self->type, $self->peer->id);
    return -1;
}

sub _pack_peer_list {
    my $self = shift;
    # Announce only peers we have actually reached ourselves, that are public and not hidden
    # (see is_announceable). Prefer higher reputation, then the most recently confirmed reachable.
    my @peers = sort {
                    ($b->reputation <=> $a->reputation)
                        || (($b->last_success_time // 0) <=> ($a->last_success_time // 0))
                }
                grep { $_->ip ne $self->peer->ip && $_->is_announceable }
                QBitcoin::Peer->get_all(PROTOCOL_QBITCOIN);
    splice(@peers, MAX_ADDR_PEERS) if @peers > MAX_ADDR_PEERS;
    my $payload = pack("C", scalar(@peers));
    $payload .= pack("a16n", $_->ip, $_->port) foreach @peers;
    return $payload;
}

sub _parse_peer_list {
    my $self = shift;
    my ($data) = @_;
    if (length($data) < 1) {
        $self->abort("incorrect_params");
        return -1;
    }
    my $count = unpack("C", substr($data, 0, 1));
    if (length($data) != 1 + $count * 18) {
        Errf("Incorrect peer list from %s: length %u, count %u", $self->peer->id, length($data), $count);
        $self->abort("incorrect_params");
        return -1;
    }
    if (!$config->{pinned_only}) { # in pinned-only mode learned peers are never dialed, do not store them
        for (my $i = 0; $i < $count; $i++) {
            my ($ip, $port) = unpack("a16n", substr($data, 1 + $i * 18, 18));
            QBitcoin::Peer->get_or_create(type_id => PROTOCOL_QBITCOIN, ip => $ip, port => $port);
        }
    }
    return $count;
}

sub send_vernak { $_[0]->send_message("vernak", $_[0]->_pack_peer_list) }
sub send_addr   { $_[0]->send_message("addr",   $_[0]->_pack_peer_list) }

sub cmd_vernak {
    my $self = shift;
    my ($data) = @_;
    my $count = $self->_parse_peer_list($data);
    return -1 if $count < 0;
    Infof("Received vernak with %u peer addresses from %s", $count, $self->peer->id);
    # Graceful rejection: the peer is at capacity. Apply the regular (exponential) connect backoff
    # so we do not reconnect to it in a tight loop and instead try the addresses it gave us.
    $self->greeted = 1;
    $self->peer->failed_connect();
    return -1;
}

sub cmd_getaddr {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 0) {
        $self->abort("incorrect_params");
        return -1;
    }
    $self->send_addr();
    return 0;
}

sub cmd_addr {
    my $self = shift;
    my ($data) = @_;
    my $count = $self->_parse_peer_list($data);
    return -1 if $count < 0;
    Debugf("Received addr with %u peer addresses from %s", $count, $self->peer->id);
    return 0;
}

sub keepalive {
    my $self = shift;
    my $time = Time::HiRes::time();
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
        my $time_us = int($time * 1000000);
        $self->send_message("ping", pack("Q", $time_us));
        $self->last_cmd_ping = $time_us;
        $self->ping_sent = $time;
    }
    return 1;
}

1;
