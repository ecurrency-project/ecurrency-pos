package QBitcoin::Network;
use warnings;
use strict;

use Time::HiRes;
use Socket;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use List::Util qw(min);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::ConnectionList;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced);
use QBitcoin::Generate;
use QBitcoin::Produce;
use QBitcoin::RPC;
use QBitcoin::REST;

sub bind_addr {
    my $class = shift;

    my ($address, $port) = split(/:/, $config->{bind} // BIND_ADDR);
    $port //= $config->{port} // getservbyname(SERVICE_NAME, 'tcp') // ($config->{testnet} ? PORT_TESTNET : PORT);
    return listen_socket($address, $port);
}

sub bind_rpc_addr {
    my $class = shift;

    my ($address, $port) = split(/:/, $config->{rpc} // RPC_ADDR);
    $port //= $config->{rpc_port} // ($config->{testnet} ? RPC_PORT_TESTNET : RPC_PORT);
    return listen_socket($address, $port);
}

sub bind_rest_addr {
    my $class = shift;

    $config->{rest} or return undef;
    my ($address, $port) = split(/:/, $config->{rest});
    $port //= $config->{rest_port} // ($config->{testnet} ? REST_PORT_TESTNET : REST_PORT);
    return listen_socket($address, $port);
}

sub listen_socket {
    my ($address, $port) = @_;
    my $bind_addr = pack_sockaddr_in($port, inet_aton($address eq '*' ? "0.0.0.0" : $address));
    my $proto = getprotobyname('tcp');
    socket(my $socket, PF_INET, SOCK_STREAM, $proto)
        or die "Error creating socket: $!\n";
    setsockopt($socket, SOL_SOCKET, SO_REUSEADDR, 1)
        or die "setsockopt error: $!\n";
    bind($socket, $bind_addr)
        or die "bind $address:$port error: $!\n";
    listen($socket, LISTEN_QUEUE)
        or die "Error listen: $!\n";
    Infof("Accepting connections on %s:%s", $address, $port);
    return $socket;
}

sub connect_to {
    my $peer = shift;
    my $iaddr = $peer->ipv4
        or die "No ipv4 address for peer " . $peer->id . "\n";
    my $paddr = pack_sockaddr_in($peer->port, $iaddr);
    my $proto = getprotobyname('tcp');
    socket(my $socket, PF_INET, SOCK_STREAM, $proto)
        or die "Error creating socket: $!\n";
    my $flags = fcntl($socket, F_GETFL, 0)
        or die "socket get fcntl error: $!\n";
    fcntl($socket, F_SETFL, $flags | O_NONBLOCK)
        or die "socket set fcntl error: $!\n";
    my $connection = QBitcoin::Connection->new(
        peer      => $peer,
        addr      => $peer->ip,
        port      => $peer->port,
        socket    => $socket,
        state     => STATE_CONNECTING,
        direction => DIR_OUT,
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

    my $generate = $config->{generate};
    $generate //= 1 if $config->{genesis};
    # By default validate blocks if there are any my coins
    $generate //= !!QBitcoin::TXO->my_utxo;

    if ($config->{genesis} && !QBitcoin::Block->blockchain_time) {
        QBitcoin::Generate->generate($config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME);
    }

    my $listen_socket = $class->bind_addr;
    my $listen_rpc    = $class->bind_rpc_addr;
    my $listen_rest   = $class->bind_rest_addr;

    set_pinned_peers();

    my ($rin, $win, $ein);
    my $sig_killed;
    $SIG{TERM} = $SIG{INT} = sub { $sig_killed = 1 };

    while () {
        QBitcoin::Block->store_blocks();
        my $timeout = SELECT_TIMEOUT;
        if (mempool_synced() && blockchain_synced()) {
            QBitcoin::Produce->produce() if $config->{produce};
            if ($generate) {
                my $time = time();
                my $generated_time = QBitcoin::Generate->generated_time;
                if (!$generated_time || timeslot($time) > timeslot($generated_time)) {
                    if ($config->{genesis} && $time > QBitcoin::Block->blockchain_time + BLOCK_INTERVAL*FORCE_BLOCKS) {
                        $time = QBitcoin::Block->blockchain_time + BLOCK_INTERVAL*FORCE_BLOCKS;
                    }
                    QBitcoin::Generate->generate($time);
                }

                my $now = Time::HiRes::time(); # generate() takes some time, get new timestamp
                my $blockchain_time = QBitcoin::Block->blockchain_time // 0;
                my $time_next_block = timeslot($blockchain_time > $now ? $blockchain_time : $now) + BLOCK_INTERVAL;
                $timeout = $time_next_block - $now;
            }
            # Debugf("Have blockchain height %d, last block time %s, weight %d", QBitcoin::Block->blockchain_height // -1, defined(QBitcoin::Block->blockchain_height) ? scalar(localtime QBitcoin::Block->blockchain_time) : "undef", QBitcoin::Block->best_weight);
        }
        $rin = $win = $ein = '';
        vec($rin, fileno($listen_socket), 1) = 1 if $listen_socket;
        vec($rin, fileno($listen_rpc),    1) = 1 if $listen_rpc;
        vec($rin, fileno($listen_rest),   1) = 1 if $listen_rest;

        call_qbt_peers();
        call_btc_peers();

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

        if ($listen_socket && vec($rin, fileno($listen_socket), 1) == 1) {
            my $peerinfo = accept(my $new_socket, $listen_socket);
            my ($remote_port, $peer_addr) = unpack_sockaddr_in($peerinfo);
            my $peer_ip = inet_ntoa($peer_addr);
            if (my $connection = QBitcoin::ConnectionList->get(PROTOCOL_QBITCOIN, IPV6_V4_PREFIX . $peer_addr)) {
                Warningf("Already connected with peer %s, status %s", $peer_ip, $connection->state);
                close($new_socket);
            }
            else {
                Infof("Incoming connection from %s", $peer_ip);
                # TODO: close listen socket if too many incoming connections; open again after disconnect some of them
                my $peer = QBitcoin::Peer->get_or_create(
                    ipv4    => $peer_addr,
                    host    => $peer_ip,
                    type_id => PROTOCOL_QBITCOIN,
                );
                # TODO: drop connection from peers with too low reputation (banned)
                my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($new_socket));
                my $my_ip = inet_ntoa($my_addr);
                my $connection = QBitcoin::Connection->new(
                    peer       => $peer,
                    socket     => $new_socket,
                    state_time => $time,
                    state      => STATE_CONNECTED,
                    port       => $remote_port,
                    my_ip      => $my_ip,
                    my_port    => $my_port,
                    my_addr    => IPV6_V4_PREFIX . $my_addr,
                    direction  => DIR_IN,
                );
                $connection->protocol->startup();
                push @connections, $connection;
            }
        }
        if ($listen_rpc && vec($rin, fileno($listen_rpc), 1) == 1) {
            my $peerinfo = accept(my $new_socket, $listen_rpc);
            my ($remote_port, $peer_addr) = unpack_sockaddr_in($peerinfo);
            my $peer_ip = inet_ntoa($peer_addr);
            # Debugf("Incoming RPC connection from %s:%u", $peer_ip, $remote_port);
            my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($new_socket));
            my $my_ip = inet_ntoa($my_addr);
            my $connection = QBitcoin::Connection->new(
                type_id    => PROTOCOL_RPC,
                socket     => $new_socket,
                state      => STATE_CONNECTED,
                state_time => $time,
                host       => $peer_ip,
                ip         => $peer_ip,
                addr       => $peer_addr,
                port       => $remote_port,
                direction  => DIR_IN,
            );
            $connection->protocol->startup();
            push @connections, $connection;
        }
        if ($listen_rest && vec($rin, fileno($listen_rest), 1) == 1) {
            my $peerinfo = accept(my $new_socket, $listen_rest);
            my ($remote_port, $peer_addr) = unpack_sockaddr_in($peerinfo);
            my $peer_ip = inet_ntoa($peer_addr);
            # Debugf("Incoming REST connection from %s:%u", $peer_ip, $remote_port);
            my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($new_socket));
            my $my_ip = inet_ntoa($my_addr);
            my $connection = QBitcoin::Connection->new(
                type_id    => PROTOCOL_REST,
                socket     => $new_socket,
                state      => STATE_CONNECTED,
                state_time => $time,
                host       => $peer_ip,
                ip         => $peer_ip,
                addr       => $peer_addr,
                port       => $remote_port,
                direction  => DIR_IN,
            );
            $connection->protocol->startup();
            push @connections, $connection;
        }

        foreach my $connection (@connections) {
            my $was_traffic;
            defined $connection->socket_fileno
                or next;
            if (vec($ein, $connection->socket_fileno, 1) == 1) {
                Warningf("%s peer %s disconnected", $connection->type, $connection->ip) unless $connection->type_id == PROTOCOL_RPC;
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
                    my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($connection->socket));
                    $connection->my_ip = inet_ntoa($my_addr);
                    $connection->my_port = $my_port;
                    $connection->my_addr = IPV6_V4_PREFIX . $my_addr,
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
    $_->update(pinned => 0) foreach values %pinned_qbtc;

    my %pinned_btc = map { $_->ip => $_ } grep { $_->pinned } QBitcoin::Peer->get_all(PROTOCOL_BITCOIN);
    foreach my $peer_host ($config->get_all('ecrnode')) {
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

sub call_btc_peers {
    my @peers = grep { $_->is_connect_allowed } QBitcoin::Peer->get_all(PROTOCOL_BITCOIN)
        or return;
    foreach my $peer (@peers) {
        connect_to($peer);
    }
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
        @peers = sort { $b->reputation <=> $a->reputation } grep { $_->reputation > 0 } @peers;
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
            next unless $peer->ipv4; # TODO
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
