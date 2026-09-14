#! /usr/bin/env perl
use warnings;
use strict;

# Outgoing connect failures must be counted for the reconnect backoff:
# - a synchronous connect() failure (no route to host: typically an IPv6 peer on a host without
#   IPv6 connectivity) is a failed connect; such a socket is reported writable with SO_ERROR == 0,
#   so without this the node would "connect" and reconnect in a tight loop eating 100% CPU
# - EINPROGRESS is the normal result of a non-blocking connect, the connection stays pending
# - an outgoing connection broken before the greeting (read error / reset) is a failed connect

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Errno qw(ENETUNREACH EINPROGRESS);

my $connect_errno;
BEGIN {
    # installed before QBitcoin::Network is compiled so its connect() calls resolve to the mock
    *CORE::GLOBAL::connect = sub (*$) { $! = $connect_errno; return 0 };
}

use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::ConnectionList;
use QBitcoin::Network;

my $next_ip = 0;
sub make_peer {
    return QBitcoin::Peer->get_or_create(
        ip      => IPV6_V4_PREFIX . pack("C4", 192, 0, 2, ++$next_ip),
        type_id => PROTOCOL_QBITCOIN,
        port    => 7000 + $next_ip,
    );
}

# Synchronous connect failure
my $peer = make_peer();
$connect_errno = ENETUNREACH;
my $connection = QBitcoin::Network::connect_to($peer);
ok(!defined $connection, "no connection object on synchronous connect failure");
is($peer->failed_connects, 1, "synchronous connect failure counted as a failed connect");
ok(defined $peer->last_fail_time, "last_fail_time set on synchronous connect failure");
ok(!$peer->is_connect_allowed, "peer is in backoff after synchronous connect failure");
is(scalar(grep { $_->peer && $_->peer == $peer } QBitcoin::ConnectionList->list()), 0,
    "failed connection not left in the connection list");

# Normal non-blocking connect in progress
$peer = make_peer();
$connect_errno = EINPROGRESS;
$connection = QBitcoin::Network::connect_to($peer);
ok($connection, "connection object created for connect in progress");
is($connection->state, STATE_CONNECTING, "connection is pending");
is($peer->failed_connects, 0, "connect in progress is not a failed connect");
ok((grep { $_ == $connection } QBitcoin::ConnectionList->list()), "pending connection is in the connection list");
ok(!$peer->is_connect_allowed, "no second dial while a connection is pending");
$connection->disconnect();

# Outgoing connection broken before the greeting (what main_loop does on a read error)
$peer = make_peer();
$connection = QBitcoin::Connection->new(
    peer      => $peer,
    state     => STATE_CONNECTED,
    direction => DIR_OUT,
    port      => $peer->port,
);
$connection->failed();
is($peer->failed_connects, 1, "outgoing connection broken before greeting is a failed connect");
is($connection->state, STATE_DISCONNECTED, "broken connection is disconnected");
ok(!$peer->is_connect_allowed, "peer is in backoff after the broken connection");

# The same after the greeting is a regular disconnect, not a failed connect
$peer = make_peer();
$connection = QBitcoin::Connection->new(
    peer      => $peer,
    state     => STATE_CONNECTED,
    direction => DIR_OUT,
    port      => $peer->port,
);
$connection->protocol->greeted = 1;
$connection->failed();
is($peer->failed_connects, 0, "greeted connection broken is not a failed connect");

done_testing();
