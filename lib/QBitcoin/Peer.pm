package QBitcoin::Peer;
use warnings;
use strict;

use Socket qw(inet_ntoa getaddrinfo unpack_sockaddr_in AF_INET SOCK_STREAM);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ORM qw(create :types);

use constant DEFAULT_INCREASE =>    1; # receive good new message (not empty block or transaction)
use constant DEFAULT_DECREASE =>  100; # one incorrect message is as 100 correct
use constant MIN_REPUTATION   => -400; # ban the peer if reputation less than this limit (after 4 bad message)

use constant TABLE => 'peer';
use constant PRIMARY_KEY => qw(type_id ip);
use constant FIELDS => {
    type_id           => NUMERIC,
    status            => NUMERIC,
    ip                => BINARY,
    port              => NUMERIC,
    create_time       => NUMERIC,
    update_time       => NUMERIC,
    software          => STRING,
    features          => NUMERIC,
    ping_min_ms       => NUMERIC,
    ping_avg_ms       => NUMERIC,
    reputation        => NUMERIC,
    failed_connects   => NUMERIC,
    last_success_time => NUMERIC, # last successful outgoing handshake; NULL == never verified reachable
    last_fail_time    => NUMERIC, # last failed outgoing connect
    hidden            => NUMERIC, # configured "hidden-peer": reachable from us but not public, never announced
    pinned            => NUMERIC,
};

mk_accessors(grep { $_ ne "reputation" } keys %{FIELDS()});
mk_accessors(qw(in_db)); # true when the peer is stored in the database (not a transient incoming-connection peer)

my @PEERS; # by type_id and ip

sub new {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    $attr->{status} //= PEER_STATUS_ACTIVE;
    return bless $attr, $class;
}

sub type { PROTOCOL2NAME->{shift->type_id} }

sub load {
    my $class = shift;
    if (!@PEERS) {
        @PEERS[$_] = {} foreach (PROTOCOL_QBITCOIN, PROTOCOL_BITCOIN);
        foreach my $peer (QBitcoin::ORM::find($class)) {
            $peer->{in_db} = 1;
            $PEERS[$peer->type_id]->{$peer->ip} = $peer;
        }
    }
}

sub get_or_create {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    $args->{ip} //= IPV6_V4_PREFIX . $args->{ipv4} if $args->{ipv4};
    my @ip;
    if ($args->{ip}) {
        @ip = ( $args->{ip} );
    }
    elsif ($args->{host}) {
        my ($addr, $port) = split(/:/, $args->{host});
        my ($err, @res) = getaddrinfo($addr, undef, { socktype => SOCK_STREAM, family => AF_INET });
        if ($err) {
            Errf("getaddrinfo for %s: %s", $addr, $err);
            return ();
        }
        @ip = map { IPV6_V4_PREFIX . unpack_sockaddr_in($_->{addr}) } @res;
        $args->{port} = $port;
    }
    else {
        Errf("Neither peer ip nor host is specified");
        return ();
    }
    my $port = $args->{port} //
        getservbyname(lc PROTOCOL2NAME->{$args->{type_id}}, 'tcp') //
        ($args->{type_id} == PROTOCOL_QBITCOIN ?
            ($config->{testnet}     ? PORT_TESTNET     : PORT    ) :
            ($config->{ecr_testnet} ? ECR_PORT_TESTNET : ECR_PORT));
    $class->load();
    my @peers;
    foreach my $ip (@ip) {
        if (my $peer = $PEERS[$args->{type_id}]->{$ip}) {
            $peer->update(port => $port) if $peer->port != $port;
            $peer->update(pinned => $args->{pinned}) if defined($args->{pinned}) && $args->{pinned} != $peer->pinned;
            $peer->update(hidden => $args->{hidden}) if defined($args->{hidden}) && $args->{hidden} != $peer->hidden;
            push @peers, $peer;
        }
        elsif ($args->{transient}) {
            # Incoming connection from an unknown peer: keep it in memory only.
            # It is stored in the database (via persist()) only after a successful greeting, so
            # random unsuccessful incoming connects do not pollute the peer table.
            push @peers, $class->new(
                type_id         => $args->{type_id},
                ip              => $ip,
                port            => $port,
                create_time     => time(),
                update_time     => time(),
                failed_connects => 0,
                reputation      => $args->{reputation} // 0,
                hidden          => $args->{hidden} // 0,
                in_db           => 0,
            );
        }
        else {
            my $peer = $class->create(
                type_id         => $args->{type_id},
                ip              => $ip,
                port            => $port,
                create_time     => time(),
                update_time     => time(),
                failed_connects => 0,
                reputation      => $args->{reputation} // 0,
                hidden          => $args->{hidden} // 0,
            );
            $peer->{in_db} = 1;
            push @peers, $PEERS[$args->{type_id}]->{$ip} = $peer;
        }
    }
    return wantarray ? @peers : $peers[0];
}

# Store a transient (incoming-connection) peer into the database after a successful greeting.
# Returns the canonical persisted peer object (may differ from $self if it became known meanwhile).
# The caller updates the port itself if it has a trustworthy one (see cmd_version).
sub persist {
    my $self = shift;
    return $self if $self->in_db;
    $self->load();
    if (my $existing = $PEERS[$self->type_id]->{$self->ip}) {
        # Became known (e.g. via addr/tx) while the handshake was in progress: adopt the stored record
        return $existing;
    }
    $self->update_time(time());
    $self->create();
    $self->{in_db} = 1;
    $PEERS[$self->type_id]->{$self->ip} = $self;
    return $self;
}

# Override ORM update(): a transient peer has no database row yet, so keep changes in memory only.
sub update {
    my $self = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };
    if (!$self->in_db) {
        foreach my $key (keys %$args) {
            my $value = $args->{$key};
            next if ref $value; # ignore raw SQL expressions (SCALAR refs) for in-memory peers
            $self->$key($value);
        }
        return;
    }
    return QBitcoin::ORM::update($self, $args);
}

sub get_all {
    my $class = shift;
    my ($type_id) = @_;
    $class->load();
    return values %{$PEERS[$type_id]};
}

sub id {
    my $self = shift;
    return $self->{id} //= $self->ipv4 ? inet_ntoa($self->ipv4) : unpack("H*", $self->ip); # TODO: ipv6
}

sub ipv4 {
    my $self = shift;
    return substr($self->ip, 0, length(IPV6_V4_PREFIX)) eq IPV6_V4_PREFIX ?
        substr($self->ip, length(IPV6_V4_PREFIX)) :
        return undef;
}

sub add_reputation {
    my $self = shift;
    my $increment = shift // DEFAULT_INCREASE;

    my $reputation = $self->reputation;
    $self->{reputation_update} = time();
    Infof("Change reputation for peer %s: %f -> %f", $self->id, $reputation, $reputation + $increment);
    $self->update(update_time => time(), reputation => $reputation + $increment);
}

sub decrease_reputation {
    my $self = shift;
    my $decrement = shift // DEFAULT_DECREASE;
    $self->add_reputation(-$decrement);
}

sub reputation {
    my $self = shift;
    if (@_) {
        $self->{reputation} = $_[0];
    }
    elsif ($self->{reputation}) {
        my $time = time();
        if (($self->{reputation_update} // 0) < $time - 300) {
            $self->{reputation_update} = $time;
            # decrease in e times during 2 weeks
            $self->{reputation} = $self->{reputation} * exp(($self->{update_time} - $time) / (3600*24*14));
        }
        return $self->{reputation};
    }
    else {
        return 0;
    }
}

sub conn_state {
    my $self = shift;
    if (my ($connection) = QBitcoin::ConnectionList->find_ip($self->type_id, $self->ip)) {
        return $connection->state;
    }
    else {
        return STATE_DISCONNECTED;
    }
}

sub is_connect_allowed {
    my $self = shift;
    return 0 if $self->conn_state != STATE_DISCONNECTED;
    return 0 if $self->status & PEER_STATUS_NOCALL;
    if ($self->failed_connects) {
        my $period = $self->failed_connects >= 10 ? 10 * 2**10 : 10 * 2**$self->failed_connects;
        return 0 if time() - ($self->last_fail_time // $self->update_time) < $period;
    }
    return 1;
}

sub failed_connect {
    my $self = shift;
    $self->update(failed_connects => $self->failed_connects + 1, last_fail_time => time());
    # failed connect does not decrease peer reputation, it may be good outgoing peer with limited incoming connections
}

# Called when an outgoing handshake completed: the peer is confirmed reachable (accepts incoming connections).
sub connect_success {
    my $self = shift;
    $self->update(last_success_time => time(), $self->failed_connects ? (failed_connects => 0) : ());
}

# True for IPs that must never be announced to other peers: private, loopback, link-local, etc.
# Argument is a packed 16-byte address (IPv4 stored as IPV6_V4_PREFIX . ipv4).
sub is_public_ip {
    my ($ip) = @_;
    return 0 unless defined($ip) && length($ip) == 16;
    if (substr($ip, 0, length(IPV6_V4_PREFIX)) eq IPV6_V4_PREFIX) {
        my @o = unpack("C4", substr($ip, length(IPV6_V4_PREFIX), 4));
        return 0 if $o[0] == 0;                                  # 0.0.0.0/8
        return 0 if $o[0] == 10;                                 # 10.0.0.0/8
        return 0 if $o[0] == 127;                                # 127.0.0.0/8 loopback
        return 0 if $o[0] == 169 && $o[1] == 254;                # 169.254.0.0/16 link-local
        return 0 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;  # 172.16.0.0/12
        return 0 if $o[0] == 192 && $o[1] == 168;                # 192.168.0.0/16
        return 0 if $o[0] == 100 && $o[1] >= 64 && $o[1] <= 127; # 100.64.0.0/10 CGNAT
        return 0 if $o[0] >= 224;                                # 224.0.0.0/4 multicast, 240.0.0.0/4 reserved, broadcast
        return 1;
    }
    else {
        return 0 if $ip eq "\x00" x 16;                          # :: unspecified
        return 0 if $ip eq "\x00" x 15 . "\x01";                 # ::1 loopback
        my $b0 = unpack("C", substr($ip, 0, 1));
        return 0 if ($b0 & 0xfe) == 0xfc;                        # fc00::/7 unique local
        my $w0 = unpack("n", substr($ip, 0, 2));
        return 0 if ($w0 & 0xffc0) == 0xfe80;                    # fe80::/10 link-local
        return 1;
    }
}

sub is_public { is_public_ip($_[0]->ip) }

# A peer must not be announced if it is explicitly hidden or has a non-public address.
sub is_hidden_addr {
    my $self = shift;
    return $self->hidden || !$self->is_public;
}

sub is_announceable {
    my $self = shift;
    return 0 if $self->is_hidden_addr;
    return 0 unless $self->port;
    return 0 unless defined $self->last_success_time;
    return 0 if $self->reputation < 0;
    return 0 if $self->failed_connects >= ANNOUNCE_MAX_FAILS;
    return 1;
}

# A peer worth probing to (re)confirm its reachability: dialable, public, not hidden, not in backoff,
# and either never verified or verified long enough ago to be worth re-checking.
sub need_probe {
    my $self = shift;
    my ($now) = @_;
    return 0 unless $self->ipv4; # TODO: ipv6
    return 0 unless $self->is_connect_allowed;
    return !defined($self->last_success_time) || $self->last_success_time < $now - PEER_REVERIFY_PERIOD;
}

# Which origin IP to advertise when re-announcing a block/transaction.
# Normally the peer we received it from; but if that peer is hidden or private we must not leak it,
# so we re-announce the upstream source ($rcvd) instead (when it is itself public).
sub announce_origin_ip {
    my $class = shift;
    my ($received_from, $rcvd) = @_;
    if ($received_from && $received_from->can('peer') && (my $peer = $received_from->peer)) {
        return $peer->ip unless $peer->is_hidden_addr;
    }
    return $rcvd if defined($rcvd) && $rcvd ne "\x00" x 16 && is_public_ip($rcvd);
    return "\x00" x 16;
}

sub recv_good_command {
    my $self = shift;
    my ($direction) = @_;

    $self->update(failed_connects => 0) if $direction == DIR_OUT && $self->failed_connects;
}

1;
