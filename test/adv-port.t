#! /usr/bin/env perl
use warnings;
use strict;

# The advertised port in the "version" message must be the node's listening port:
# - we advertise the configured listen port, not the ephemeral port of the outgoing socket
# - the advertised port of the peer is stored only when it can be trusted (the nonce is
#   present: older nodes mistakenly advertise the ephemeral port of their socket)
# - advertised port 0 means "no incoming connections", such peers are not stored for dial-back

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM; # in-memory sqlite, needed for peer persist() on incoming greeting
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Protocol;
use QBitcoin::ProtocolState qw(btc_synced);

btc_synced(1); # do not request btc blocks on greeting

my $next_ip = 0;
sub make_connection {
    my %args = @_;
    my $peer = QBitcoin::Peer->get_or_create(
        ip        => $args{ip} // (IPV6_V4_PREFIX . pack("C4", 192, 0, 2, ++$next_ip)),
        type_id   => PROTOCOL_QBITCOIN,
        transient => 1,
    );
    return QBitcoin::Connection->new(
        peer      => $peer,
        state     => STATE_CONNECTED,
        direction => $args{direction} // DIR_IN,
        port      => 50000 + $next_ip,
        my_addr   => IPV6_V4_PREFIX . pack("C4", 127, 0, 0, 1),
        my_port   => 33333, # ephemeral port of the socket, must not be advertised
    );
}

my $next_nonce = 0;
sub recv_version {
    my ($connection, %args) = @_;
    my $payload = pack("VQ<Q<a26", 1, 0, time(), pack("Q<a16n", 0, $connection->peer->ip, $args{adv_port}));
    $payload .= pack("Q<", ++$next_nonce) unless $args{old_format};
    $connection->protocol->command("version");
    return $connection->protocol->cmd_version($payload);
}

sub sent_adv_port {
    my ($connection) = @_;
    # 24-byte message header, then version:4 features:8 time:8, then my_address: features:8 addr:16 port:2
    my (undef, undef, $adv_port) = unpack("Q<a16n", substr($connection->sendbuf, 24 + 20, 26));
    return $adv_port;
}

# We advertise the configured listening port, not the local port of the connection
$config->{port} = 12345;
my $conn_out = make_connection(direction => DIR_OUT);
$conn_out->protocol->startup();
is(sent_adv_port($conn_out), 12345, "configured port advertised instead of the socket port");

# The port from the "bind" option has higher priority (it is the really listening one)
$config->{bind} = "127.0.0.1:7777";
$conn_out = make_connection(direction => DIR_OUT);
$conn_out->protocol->startup();
is(sent_adv_port($conn_out), 7777, "port from the bind address advertised");
delete $config->{bind};
delete $config->{port};

# Advertised port of a new node (with nonce) is stored in the peer record
my $conn = make_connection();
is(recv_version($conn, adv_port => 7000), 0, "new node greeted");
ok($conn->peer->in_db, "peer stored");
is($conn->peer->port, 7000, "advertised port stored");

# Advertised port of an old node (no nonce) is not trusted: it is the ephemeral port of its socket
$conn = make_connection();
my $default_port = $conn->peer->port;
is(recv_version($conn, adv_port => 54321, old_format => 1), 0, "old node greeted");
ok($conn->peer->in_db, "old node peer stored");
is($conn->peer->port, $default_port, "ephemeral port from an old node ignored, default port kept");

# Advertised port 0: the node does not accept incoming connections and must not be stored
$conn = make_connection();
is(recv_version($conn, adv_port => 0), 0, "node without incoming connections greeted");
ok(!$conn->peer->in_db, "non-dialable peer not stored");

# A known peer record is updated with the trusted advertised port
my $known_ip = IPV6_V4_PREFIX . pack("C4", 192, 0, 2, 200);
my $known = QBitcoin::Peer->get_or_create(ip => $known_ip, type_id => PROTOCOL_QBITCOIN, port => 1111);
ok($known->in_db, "known peer is in the database");
$conn = make_connection(ip => $known_ip);
is(recv_version($conn, adv_port => 8888), 0, "known peer greeted");
is($known->port, 8888, "known peer port updated from the trusted advertisement");

done_testing();
