package QBitcoin::Network;
use warnings;
use strict;
use feature 'state';

use Time::HiRes;
use Socket qw(:DEFAULT inet_pton pack_sockaddr_in6 AF_INET6 PF_INET6 IPPROTO_IPV6 IPV6_V6ONLY);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use List::Util qw(min);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::IP qw(ip_str ip_port_str parse_addr_port sockaddr_to_ip_port pack_sockaddr_by_ip);
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::ConnectionList;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced btc_synced sync_peer last_qbt_data_time);
use QBitcoin::CheckPoints qw(upgrade_finished);
use QBitcoin::Generate;
use QBitcoin::Coins;
use QBitcoin::Produce;
use QBitcoin::RPC;
use QBitcoin::REST;

sub bind_addr {
    my $class = shift;

    my ($address) = parse_addr_port($config->{bind} // BIND_ADDR);
    # the same port is advertised to peers in the "version" message
    return [ listen_sockets($address, QBitcoin::Protocol::listen_port()) ];
}

sub bind_rpc_addr {
    my $class = shift;

    my ($address, $port) = parse_addr_port($config->{rpc} // RPC_ADDR);
    $port //= $config->{rpc_port} // ($config->{testnet} ? RPC_PORT_TESTNET : RPC_PORT);
    return [ listen_sockets($address, $port) ];
}

sub bind_rest_addr {
    my $class = shift;

    $config->{rest} or return [];
    my ($address, $port) = parse_addr_port($config->{rest});
    $port //= $config->{rest_port} // ($config->{testnet} ? REST_PORT_TESTNET : REST_PORT);
    return [ listen_sockets($address, $port) ];
}

# Listening socket(s) for the given address; "*" means all addresses of both
# families, i.e. separate IPv4 and IPv6 sockets (IPv6 one is skipped with a
# warning on a host without IPv6 support)
sub listen_sockets {
    my ($address, $port) = @_;
    $address eq '*'
        or return listen_socket($address, $port);
    my @sockets = ( listen_socket("0.0.0.0", $port) );
    if (my $socket6 = eval { listen_socket("::", $port) }) {
        push @sockets, $socket6;
    }
    else {
        Warningf("Cannot listen on [::]:%u: %s", $port, $@ =~ s/\n\z//r);
    }
    return @sockets;
}

sub listen_socket {
    my ($address, $port) = @_;
    my ($family, $bind_addr);
    if (defined(my $addr6 = inet_pton(AF_INET6, $address))) {
        $family = PF_INET6;
        $bind_addr = pack_sockaddr_in6($port, $addr6);
    }
    elsif (defined(my $addr4 = inet_pton(AF_INET, $address))) {
        $family = PF_INET;
        $bind_addr = pack_sockaddr_in($port, $addr4);
    }
    else {
        die "Incorrect bind address $address\n";
    }
    my $proto = getprotobyname('tcp');
    socket(my $socket, $family, SOCK_STREAM, $proto)
        or die "Error creating socket: $!\n";
    setsockopt($socket, SOL_SOCKET, SO_REUSEADDR, 1)
        or die "setsockopt error: $!\n";
    if ($family == PF_INET6) {
        # do not intercept IPv4-mapped connections, IPv4 is served by its own socket
        setsockopt($socket, IPPROTO_IPV6, IPV6_V6ONLY, 1)
            or die "setsockopt IPV6_V6ONLY error: $!\n";
    }
    my $addr_str = $family == PF_INET6 ? "[$address]:$port" : "$address:$port";
    bind($socket, $bind_addr)
        or die "bind $addr_str error: $!\n";
    listen($socket, LISTEN_QUEUE)
        or die "Error listen: $!\n";
    Infof("Accepting connections on %s", $addr_str);
    return $socket;
}

sub connect_to {
    my $peer = shift;
    my %opts = @_;
    my ($family, $paddr) = pack_sockaddr_by_ip($peer->port, $peer->ip);
    my $proto = getprotobyname('tcp');
    my $socket;
    unless (socket($socket, $family, SOCK_STREAM, $proto)) {
        # typically EAFNOSUPPORT: an IPv6 peer on a host without IPv6 support;
        # count as a failed connect so the backoff prevents retrying every loop
        Warningf("Error creating socket for peer %s: %s", $peer->id, $!);
        $peer->failed_connect();
        return undef;
    }
    my $flags = fcntl($socket, F_GETFL, 0)
        or die "socket get fcntl error: $!\n";
    fcntl($socket, F_SETFL, $flags | O_NONBLOCK)
        or die "socket set fcntl error: $!\n";
    my $connection = QBitcoin::Connection->new(
        peer       => $peer,
        addr       => $peer->ip,
        port       => $peer->port,
        socket     => $socket,
        state      => STATE_CONNECTING,
        direction  => DIR_OUT,
        bytes_sent => 0,
        bytes_recv => 0,
        obj_sent   => 0,
        obj_recv   => 0,
        $opts{probe} ? (probe => 1) : (),
    );
    connect($socket, $paddr);
    Debugf("Connecting to %s peer %s:%u", $peer->type, $peer->id, $peer->port);
    $peer->update(update_time => time());
    return $connection;
}

sub main_loop {
    my $class = shift;
    my ($peer_hosts, $btc_nodes) = @_;

    local $SIG{PIPE} = 'IGNORE'; # prevent exceptions on write to socket which was closed by remote

    if ($config->{genesis}) {
        mempool_synced(1);
        blockchain_synced(1);
        last_qbt_data_time(time());
    }
    if (upgrade_finished()) {
        btc_synced(1);
    }
    # Load last block from database
    while (my ($block) = QBitcoin::Block->find(-sortby => "height DESC", -limit => 1)) {
        foreach my $tx (@{$block->transactions}) {
            $tx->add_to_cache();
            $tx->add_to_block($block);
        }
        QBitcoin::Block->max_db_height($block->height);
        $block->prev_block_load;
        if ($block->receive(1) != 0) {
            Errf("Incorrect stored block %s height %u, delete", $block->hash_str, $block->height);
            $block->delete();
            QBitcoin::Block->max_db_height($block->height - 1);
            next;
        }
        Debugf("Loaded block height %u", $block->height);
        last;
    }
    # Load my UTXO for generate or rpc getbalance
    QBitcoin::Generate->load_utxo();
    # Compute the base of the emitted coins counter; afterwards it is maintained
    # incrementally on confirm/unconfirm of coinbase and stake transactions
    QBitcoin::Coins->init();

    my $generate = $config->{generate};
    $generate //= 1 if $config->{genesis};
    # By default validate blocks if there are any my staked coins
    $generate //= !!QBitcoin::TXO->staked_utxo;

    # Slashing self-guard: remember the slot we start in. Until the in-memory registry of
    # published stakes is repopulated, we must not (re)stake this slot or any earlier one
    # (we may have already published a stake for them in a previous run before a restart).
    QBitcoin::Generate::Control->start_slot(timeslot(time())) if $generate;

    if ($config->{genesis} && !QBitcoin::Block->blockchain_time) {
        my $genesis_time = $config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME;
        $genesis_time % BLOCK_INTERVAL == 0
            or die "Genesis time $genesis_time is not a multiple of block interval " . BLOCK_INTERVAL;
        QBitcoin::Generate->generate($genesis_time);
    }

    my @listen_socket = @{$class->bind_addr};
    my @listen_rpc    = @{$class->bind_rpc_addr};
    my @listen_rest   = @{$class->bind_rest_addr};

    set_pinned_peers();

    my ($rin, $win, $ein);
    my $sig_killed;
    $SIG{TERM} = $SIG{INT} = sub { $sig_killed = 1 };

    while () {
        QBitcoin::Block->store_blocks();
        my $timeout = SELECT_TIMEOUT;
        if (!$config->{genesis} && !QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN)) {
            blockchain_synced(0);
            mempool_synced(0);
            if (UPGRADE_POW && !upgrade_finished() && !QBitcoin::ConnectionList->connected(PROTOCOL_BITCOIN)) {
                btc_synced(0);
            }
        }
        if (mempool_synced() && blockchain_synced()) {
            QBitcoin::Produce->produce() if $config->{produce};
            if ($generate) {
                my $time = time();
                my $timeslot = timeslot($time);
                my $generated_time = QBitcoin::Generate->generated_time;
                my $blockchain_time = QBitcoin::Block->blockchain_time // 0;
                my $defer_until; # wall-clock moment to wake for a delayed current-slot block
                if (!$generated_time || $timeslot > timeslot($generated_time)) {
                    state $genesis_time = $config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME;
                    my $next_forced = $blockchain_time - ($blockchain_time - $genesis_time) % (BLOCK_INTERVAL*FORCE_BLOCKS) + BLOCK_INTERVAL*FORCE_BLOCKS;
                    if ($config->{genesis} && $timeslot > $next_forced) {
                        $timeslot = $next_forced;
                    }
                    if ($timeslot <= $next_forced) {
                        # Randomized in-slot delay before producing the current slot's block:
                        # wait a bit after the slot start so we can first see peers' blocks and
                        # collect more transactions (incl. slashing), and not commit our single
                        # per-slot stake to a block that is about to be outcompeted. Applies
                        # only to the current slot; a past slot (genesis catch-up / forced for
                        # elapsed time) is produced immediately, and genesis (height 0) does not
                        # reach this path.
                        my $gen_at = $timeslot == timeslot($time)
                            ? QBitcoin::Generate->gen_time($timeslot) : 0;
                        if (Time::HiRes::time() >= $gen_at) {
                            QBitcoin::Generate->generate($timeslot);
                            $blockchain_time = QBitcoin::Block->blockchain_time // 0;
                        }
                        else {
                            $defer_until = $gen_at;
                        }
                    }
                    else {
                        blockchain_synced(0);
                    }
                }

                my $now = Time::HiRes::time(); # generate() takes some time, get new timestamp
                my $time_next_block = timeslot($blockchain_time > $now ? $blockchain_time : $now) + BLOCK_INTERVAL;
                $timeout = $time_next_block - $now;
                # Wake earlier, at the randomized in-slot moment, if generation is deferred.
                $timeout = $defer_until - $now if defined($defer_until) && $defer_until - $now < $timeout;
            }
            # Debugf("Have blockchain height %d, last block time %s, weight %d", QBitcoin::Block->blockchain_height // -1, defined(QBitcoin::Block->blockchain_height) ? scalar(localtime QBitcoin::Block->blockchain_time) : "undef", QBitcoin::Block->best_weight);
        }
        $rin = $win = $ein = '';
        vec($rin, fileno($_), 1) = 1 foreach @listen_socket, @listen_rpc, @listen_rest;

        call_qbt_peers();
        call_btc_peers();
        check_probes();
        probe_peers();
        check_blockchain_alive();
        check_sync_peer();

        my @connections = QBitcoin::ConnectionList->list;
        foreach my $connection (@connections) {
            vec($rin, $connection->socket_fileno, 1) = 1 if length($connection->recvbuf) < READ_BUFFER_SIZE && $connection->state != STATE_CONNECTING;
            vec($win, $connection->socket_fileno, 1) = 1 if $connection->sendbuf || $connection->state == STATE_CONNECTING;
        }

        $ein = $rin | $win;
        my $nfound = select($rin, $win, $ein, $timeout);
        last if $sig_killed;
        if ($nfound == -1) {
            Errf("select error: %s", $!);
            last;
        }
        my $time = time();

        foreach my $listen_socket (grep { vec($rin, fileno($_), 1) == 1 } @listen_socket) {
            my $peerinfo = accept(my $new_socket, $listen_socket);
            my ($remote_port, $peer_addr) = sockaddr_to_ip_port($peerinfo);
            my $peer_ip = ip_str($peer_addr);
            # Do not reject a duplicate IP here: several nodes behind one NAT address may connect
            # from the same IP. Duplicate connections with the same node are detected by the session
            # nonce from the "version" message (see QBitcoin::Protocol::check_duplicate_connection),
            # here we only limit the number of incoming connections per IP.
            my $in_from_ip = grep { $_->direction == DIR_IN }
                QBitcoin::ConnectionList->find_ip(PROTOCOL_QBITCOIN, $peer_addr);
            if ($in_from_ip >= ($config->{max_in_connections_per_ip} // MAX_IN_CONNECTIONS_PER_IP)) {
                Warningf("Too many incoming connections from %s (%u), reject", $peer_ip, $in_from_ip);
                close($new_socket);
            }
            else {
                Infof("Incoming connection from %s", $peer_ip);
                my $peer = QBitcoin::Peer->get_or_create(
                    ip        => $peer_addr,
                    type_id   => PROTOCOL_QBITCOIN,
                    transient => 1, # persisted only after a successful greeting, see QBitcoin::Peer::persist
                );
                # TODO: drop connection from peers with too low reputation (banned)
                my ($my_port, $my_addr) = sockaddr_to_ip_port(getsockname($new_socket));
                my $my_ip = ip_str($my_addr);
                my $in_count = grep { $_->type_id == PROTOCOL_QBITCOIN && $_->direction == DIR_IN }
                               QBitcoin::ConnectionList->list();
                my $connection = QBitcoin::Connection->new(
                    peer       => $peer,
                    socket     => $new_socket,
                    state_time => $time,
                    state      => STATE_CONNECTED,
                    port       => $remote_port,
                    my_ip      => $my_ip,
                    my_port    => $my_port,
                    my_addr    => $my_addr,
                    direction  => DIR_IN,
                    bytes_sent => 0,
                    bytes_recv => 0,
                    obj_sent   => 0,
                    obj_recv   => 0,
                );
                if ($in_count >= ($config->{max_in_connections} // MAX_IN_CONNECTIONS)) {
                    Infof("Too many incoming connections (%u), will send vernak to %s", $in_count, $peer_ip);
                    $connection->protocol->reject_with_peers(1);
                }
                else {
                    $connection->protocol->startup();
                }
                push @connections, $connection;
            }
        }
        foreach my $listen_rpc (grep { vec($rin, fileno($_), 1) == 1 } @listen_rpc) {
            my $peerinfo = accept(my $new_socket, $listen_rpc);
            my ($remote_port, $peer_addr) = sockaddr_to_ip_port($peerinfo);
            my $peer_ip = ip_str($peer_addr);
            my @rpc_connections = grep { $_->type_id == PROTOCOL_RPC } QBitcoin::ConnectionList->list();
            if (@rpc_connections >= ($config->{max_rpc_connections} // MAX_RPC_CONNECTIONS)) {
                Warningf("Too many RPC connections (%u), reject from %s", scalar(@rpc_connections), $peer_ip);
                close($new_socket);
            }
            else {
                # Debugf("Incoming RPC connection from %s:%u", $peer_ip, $remote_port);
                my ($my_port, $my_addr) = sockaddr_to_ip_port(getsockname($new_socket));
                my $my_ip = ip_str($my_addr);
                my $connection = QBitcoin::Connection->new(
                    type_id    => PROTOCOL_RPC,
                    socket     => $new_socket,
                    state      => STATE_CONNECTED,
                    state_time => $time,
                    host       => $peer_ip,
                    ip         => $peer_ip,
                    addr       => $peer_addr,
                    port       => $remote_port,
                    my_ip      => $my_ip,
                    my_port    => $my_port,
                    my_addr    => $my_addr,
                    direction  => DIR_IN,
                );
                $connection->protocol->startup();
                push @connections, $connection;
            }
        }
        foreach my $listen_rest (grep { vec($rin, fileno($_), 1) == 1 } @listen_rest) {
            my $peerinfo = accept(my $new_socket, $listen_rest);
            my ($remote_port, $peer_addr) = sockaddr_to_ip_port($peerinfo);
            my $peer_ip = ip_str($peer_addr);
            my @rest_connections = grep { $_->type_id == PROTOCOL_REST } QBitcoin::ConnectionList->list();
            if (@rest_connections >= ($config->{max_rest_connections} // MAX_REST_CONNECTIONS)) {
                Warningf("Too many REST connections (%u), reject from %s", scalar(@rest_connections), $peer_ip);
                close($new_socket);
            }
            else {
                # Debugf("Incoming REST connection from %s:%u", $peer_ip, $remote_port);
                my ($my_port, $my_addr) = sockaddr_to_ip_port(getsockname($new_socket));
                my $my_ip = ip_str($my_addr);
                my $connection = QBitcoin::Connection->new(
                    type_id    => PROTOCOL_REST,
                    socket     => $new_socket,
                    state      => STATE_CONNECTED,
                    state_time => $time,
                    host       => $peer_ip,
                    ip         => $peer_ip,
                    addr       => $peer_addr,
                    port       => $remote_port,
                    my_ip      => $my_ip,
                    my_port    => $my_port,
                    my_addr    => $my_addr,
                    direction  => DIR_IN,
                );
                $connection->protocol->startup();
                push @connections, $connection;
            }
        }

        foreach my $connection (@connections) {
            my $was_traffic;
            defined $connection->socket_fileno
                or next;
            if (vec($ein, $connection->socket_fileno, 1) == 1) {
                if ($connection->type_id != PROTOCOL_RPC && $connection->type_id != PROTOCOL_REST) {
                    Warningf("%s peer %s disconnected", $connection->type, $connection->ip);
                }
                $connection->failed();
                next;
            }

            if (vec($rin, $connection->socket_fileno, 1) == 1) {
                my $n = sysread($connection->socket, my $data, READ_BUFFER_SIZE);
                if (!defined $n) {
                    if ($sig_killed) {
                        Notice("Killed by signal");
                        $connection->disconnect();
                        last;
                    }
                    elsif ($connection->state == STATE_CONNECTING) {
                        Warningf("%s peer %s connection error: %s", $connection->type, $connection->ip, $!);
                        $connection->failed();
                        next;
                    }
                    else {
                        Warningf("Read error from %s peer %s", $connection->type, $connection->ip);
                    }
                    $connection->disconnect();
                    next;
                }
                if ($n > 0) {
                    $connection->recvbuf .= $data;
                    $was_traffic = 1;
                }
                elsif ($n == 0) {
                    Warningf("%s peer %s closed connection", $connection->type, $connection->ip);
                    $connection->failed();
                    next;
                }
            }
            if (vec($win, $connection->socket_fileno, 1) == 1) {
                if ($connection->state == STATE_CONNECTING) {
                    my $res = getsockopt($connection->socket, SOL_SOCKET, SO_ERROR);
                    my $err = unpack("I", $res);
                    if ($err != 0) {
                        local $! = $err;
                        Warningf("Connect to %s peer %s error: %s", $connection->type, $connection->ip, $!);
                        $connection->failed();
                        next;
                    }
                    $connection->state = STATE_CONNECTED;
                    $connection->state_time = time();
                    my ($my_port, $my_addr) = sockaddr_to_ip_port(getsockname($connection->socket));
                    $connection->my_ip = ip_str($my_addr);
                    $connection->my_port = $my_port;
                    $connection->my_addr = $my_addr;
                    Infof("Connected to %s peer %s", $connection->type, $connection->ip);
                    $connection->protocol->startup();
                    next;
                }
                my $n = syswrite($connection->socket, $connection->sendbuf, length($connection->sendbuf));
                if (!defined $n) {
                    if ($sig_killed) {
                        Notice("Interrupted by signal");
                        $connection->disconnect();
                        last;
                    }
                    Warningf("Write error to %s peer %s", $connection->type, $connection->ip);
                    $connection->failed();
                    next;
                }
                elsif ($n > 0) {
                    $connection->sendbuf = $n == length($connection->sendbuf) ? "" : substr($connection->sendbuf, $n);
                    $was_traffic = 1;
                    if (!$connection->sendbuf && ($connection->type_id == PROTOCOL_RPC || $connection->type_id == PROTOCOL_REST)) {
                        $connection->disconnect();
                        next;
                    }
                }
            }
            # recvbuf may be not empty after skip some commands due to full sendbuf
            # in this case we will process recvbuf after sending some data from sendbuf without receiving anything new
            if ($was_traffic && $connection->recvbuf) {
                my $ret = $connection->protocol->receive();
                if ($ret != 0) {
                    $connection->failed();
                    next;
                }
                next unless $connection->protocol; # RPC can call disconnect() from receive() call
            }

            if ($connection->state == STATE_CONNECTED && $connection->protocol->can('keepalive')) {
                if (!$connection->protocol->keepalive()) {
                    Noticef("%s peer %s timeout, closing connection", $connection->type, $connection->ip);
                    $connection->disconnect();
                    next;
                }
            }
            if ($connection->protocol->can('timeout')) {
                my $peer_timeout = $connection->protocol->timeout($time);
                if ($peer_timeout) {
                    $timeout = $peer_timeout if $timeout > $peer_timeout;
                }
                else {
                    Noticef("%s peer %s timeout", $connection->type, $connection->ip);
                    $connection->failed();
                    next;
                }
            }
        }
    }
    return 0;
}

sub set_pinned_peers {
    my %pinned_qbtc = map { $_->ip => $_ } grep { $_->pinned } QBitcoin::Peer->get_all(PROTOCOL_QBITCOIN);
    my %hidden_qbtc = map { $_->ip => $_ } grep { $_->hidden } QBitcoin::Peer->get_all(PROTOCOL_QBITCOIN);
    foreach my $peer_host ($config->get_all('peer')) {
        my @peers = QBitcoin::Peer->get_or_create(
            host       => $peer_host,
            type_id    => PROTOCOL_QBITCOIN,
            pinned     => 1,
            reputation => 1000,
        )
            or next;
        delete @pinned_qbtc{ map { $_->ip } @peers };
    }
    # "hidden-peer": only mark the peer as hidden (never announce it / hide it as object origin).
    # This does NOT pin the peer and does NOT trigger outgoing connections to it; to also connect
    # to a hidden peer, list it under "peer" as well (it will then be both pinned and hidden).
    foreach my $peer_host ($config->get_all('hidden_peer')) {
        my @peers = QBitcoin::Peer->get_or_create(
            host    => $peer_host,
            type_id => PROTOCOL_QBITCOIN,
            hidden  => 1,
        )
            or next;
        delete @hidden_qbtc{ map { $_->ip } @peers };
    }
    $_->update(pinned => 0) foreach values %pinned_qbtc;
    $_->update(hidden => 0) foreach values %hidden_qbtc;

    if (!upgrade_finished()) {
        my %pinned_btc = map { $_->ip => $_ } grep { $_->pinned } QBitcoin::Peer->get_all(PROTOCOL_BITCOIN);
        foreach my $peer_host ($config->get_all('btcnode')) {
            my @peers = QBitcoin::Peer->get_or_create(
                host    => $peer_host,
                type_id => PROTOCOL_BITCOIN,
                pinned  => 1,
            )
                or next;
            delete @pinned_btc{ map { $_->ip } @peers };
        }
        $_->update(pinned => 0) foreach values %pinned_btc;
    }
}

sub check_blockchain_alive {
    return unless blockchain_synced();
    return unless last_qbt_data_time();
    return if $config->{genesis};
    if (time() - last_qbt_data_time() > (2 * FORCE_BLOCKS + 1) * BLOCK_INTERVAL) {
        Warningf("No new blocks or transactions received from peers for %u seconds, resetting sync state",
            time() - last_qbt_data_time());
        blockchain_synced(0);
        mempool_synced(0);
    }
}

sub check_sync_peer {
    if (blockchain_synced()) {
        sync_peer(undef);
        return;
    }
    if (my $sp = sync_peer()) {
        if (!$sp->connection || $sp->connection->state != STATE_CONNECTED) {
            Infof("Sync peer %s disconnected, selecting new sync peer", $sp->peer->id);
            sync_peer(undef);
        }
        elsif (Time::HiRes::time() - $sp->last_recv_time > SYNC_PEER_TIMEOUT) {
            Infof("Sync peer %s timed out (no data for %u sec), selecting new sync peer", $sp->peer->id, SYNC_PEER_TIMEOUT);
            $sp->syncing(0);
            sync_peer(undef);
        }
        else {
            return;
        }
    }
    # Select new sync peer: prefer highest has_weight, then lowest ping_avg_ms
    my $best;
    foreach my $connection (grep { $_->type_id == PROTOCOL_QBITCOIN && $_->state == STATE_CONNECTED } QBitcoin::ConnectionList->list()) {
        my $proto = $connection->protocol;
        next unless $proto->greeted;
        next unless defined $proto->has_weight;
        next if ($connection->peer->reputation // 0) < QBitcoin::Peer::MIN_REPUTATION;
        if (!$best
            || ($proto->has_weight // -1) > ($best->has_weight // -1)
            || ($proto->has_weight // -1) == ($best->has_weight // -1)
                && ($proto->peer->ping_avg_ms // 9999) < ($best->peer->ping_avg_ms // 9999))
        {
            $best = $proto;
        }
    }
    if ($best) {
        Infof("Selected sync peer %s (weight %Lu, ping %s ms)", $best->peer->id,
            $best->has_weight // 0, $best->peer->ping_avg_ms // "?");
        sync_peer($best);
        if (!$best->syncing) {
            $best->request_new_block();
        }
    }
}

sub call_btc_peers {
    return if upgrade_finished();
    my @peers = grep { $_->is_connect_allowed } QBitcoin::Peer->get_all(PROTOCOL_BITCOIN)
        or return;
    foreach my $peer (@peers) {
        connect_to($peer);
    }
}

# Tear down reachability-probe connections once the greeting has confirmed the peer is alive:
# the probe only needs to set last_success_time (done on greeting), we do not keep the connection.
sub check_probes {
    foreach my $connection (grep { $_->probe } QBitcoin::ConnectionList->list()) {
        next unless $connection->state == STATE_CONNECTED;
        next unless $connection->protocol && $connection->protocol->greeted;
        Debugf("Reachability probe of peer %s succeeded, disconnecting", $connection->peer->id);
        $connection->disconnect();
    }
}

my $last_probe_time = 0;
# Periodically probe an idle peer (typically a zero-reputation one we never dialed) to learn whether
# it is reachable. Confirmed peers then become announceable (see QBitcoin::Peer::is_announceable),
# so a node can advertise its many idle peers instead of only the few it actively talks to.
sub probe_peers {
    blockchain_synced() # do not interfere with the initial synchronization
        or return;
    my $now = time();
    $now - $last_probe_time >= PEER_PROBE_PERIOD
        or return;
    my $active = grep { $_->probe } QBitcoin::ConnectionList->list();
    $active < MAX_PROBE_CONNECTIONS
        or return;
    my @candidates = grep { $_->need_probe($now) } QBitcoin::Peer->get_all(PROTOCOL_QBITCOIN)
        or return;
    # Round-robin: probe the least recently contacted peer first.
    my ($peer) = sort { ($a->update_time // 0) <=> ($b->update_time // 0) } @candidates;
    $last_probe_time = $now;
    Debugf("Probing peer %s to verify reachability", $peer->id);
    connect_to($peer, probe => 1);
}

sub call_qbt_peers {
    my @peers = grep { $_->is_connect_allowed } QBitcoin::Peer->get_all(PROTOCOL_QBITCOIN);
    if (!@peers) {
        my @fallback_peer = $config->get_all('fallback_peer');
        my $seed_peer = $config->{testnet} ? SEED_PEER_TESTNET : SEED_PEER;
        @fallback_peer = ($seed_peer) if $seed_peer && !@fallback_peer;
        foreach my $peer_host (@fallback_peer) {
            push @peers, grep { $_->is_connect_allowed } QBitcoin::Peer->get_or_create(
                host       => $peer_host,
                type_id    => PROTOCOL_QBITCOIN,
                reputation => 10,
            )
        }
        return unless @peers;
    }
    my $found_pinned;
    foreach my $peer (grep { $_->pinned } @peers) {
        connect_to($peer);
        $found_pinned++;
    }
    @peers = grep { !$_->pinned } @peers if $found_pinned;
    my $connect_in = 0;
    my $connect_out = 0;
    foreach my $connection (grep { $_->type_id == PROTOCOL_QBITCOIN } QBitcoin::ConnectionList->list()) {
        $connection->direction == DIR_IN ? $connect_in++ : $connect_out++;
    }
    if ($connect_in + $connect_out < MIN_CONNECTIONS || $connect_out < MIN_OUT_CONNECTIONS+1) {
        # reputation >= 0: also try neutral peers we have never connected to yet (e.g. addresses
        # just learned from vernak/addr), otherwise a node could never bootstrap past a full seed.
        # Only peers that misbehaved (negative reputation) are skipped here.
        @peers = sort { $b->reputation <=> $a->reputation } grep { $_->reputation >= 0 } @peers;
        my @connected = grep { $_->type_id == PROTOCOL_QBITCOIN && $_->direction == DIR_OUT && $_->state == STATE_CONNECTED }
            QBitcoin::ConnectionList->list();
        my $worst_reputation = min map { $_->peer->reputation } @connected;
        # If we have disconnected peer with reputation more than worse of our connected -> connect to it
        while (@peers && ($connect_in + $connect_out <= MIN_CONNECTIONS || $connect_out <= MIN_OUT_CONNECTIONS)) {
            my $peer = shift @peers;
            if (@connected &&
                $connect_out >= MIN_OUT_CONNECTIONS &&
                $connect_in + $connect_out >= MIN_CONNECTIONS &&
                $peer->reputation <= $worst_reputation) {
                last;
            }
            if (connect_to($peer)) {
                $connect_out++;
            }
        }
        # if we have MIN_OUT_CONNECTION+1 connected peers than disconnect from worst
        if (@connected > MIN_OUT_CONNECTIONS && $connect_in + $connect_out > MIN_CONNECTIONS) {
            my ($connection) = grep { $_->peer->reputation <= $worst_reputation } @connected;
            if ($connection) {
                Infof("Disconnect from %s peer %s, too many connections", $connection->type, $connection->peer->id);
                $connection->disconnect;
            }
        }
    }
}

1;
