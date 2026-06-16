#! /usr/bin/env perl
use warnings;
use strict;

# Deduplication of p2p connections by the "version" session nonce:
# - several nodes behind one NAT address can be connected at the same time
# - two connections with the same node (mutual connect, reconnect) are reduced to one
# - self-connections are rejected
# - old nodes (no nonce in "version") keep the legacy "single connection per IP" rule

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM; # in-memory sqlite, needed for peer persist() on incoming greeting
use QBitcoin::Const;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::ConnectionList;
use QBitcoin::Protocol;
use QBitcoin::ProtocolState qw(btc_synced);

btc_synced(1); # do not request btc blocks on greeting

sub ip4 { IPV6_V4_PREFIX . pack("C4", split(/\./, $_[0])) }

sub make_connection {
    my %args = @_;
    my $peer = QBitcoin::Peer->get_or_create(
        ip        => $args{ip},
        type_id   => PROTOCOL_QBITCOIN,
        transient => 1,
    );
    return QBitcoin::Connection->new(
        peer      => $peer,
        state     => STATE_CONNECTED,
        direction => $args{direction},
        port      => $args{port},
        $args{probe} ? (probe => 1) : (),
    );
}

sub recv_version {
    my ($connection, %args) = @_;
    my $payload = pack("VQ<Q<a26", 1, 0, time(), pack("Q<a16n", 0, $connection->peer->ip, PORT));
    $payload .= $args{nonce} if defined $args{nonce};
    $connection->protocol->command("version");
    return $connection->protocol->cmd_version($payload);
}

my $nonce_a = "AAAAAAAA";
my $nonce_b = "BBBBBBBB";

# Two different nodes behind one NAT address connected in parallel
my $nat_ip = ip4("203.0.113.7");
my $conn_a = make_connection(ip => $nat_ip, direction => DIR_IN, port => 50001);
my $conn_b = make_connection(ip => $nat_ip, direction => DIR_IN, port => 50002);
is(recv_version($conn_a, nonce => $nonce_a), 0, "first node behind NAT greeted");
is(recv_version($conn_b, nonce => $nonce_b), 0, "second node behind the same NAT greeted");
is($conn_a->state, STATE_CONNECTED, "first connection stays alive");
is($conn_b->state, STATE_CONNECTED, "second connection stays alive");

# The same node connects again (reconnect after silent disconnect): the old session is dropped
my $conn_a2 = make_connection(ip => $nat_ip, direction => DIR_IN, port => 50003);
is(recv_version($conn_a2, nonce => $nonce_a), 0, "reconnect of the same node greeted");
is($conn_a->state, STATE_DISCONNECTED, "stale session with the same node dropped");
is($conn_a2->state, STATE_CONNECTED, "new session with the same node stays alive");
is($conn_b->state, STATE_CONNECTED, "session with the other node is not affected");

# Self-connection: remote nonce equals our own
my $conn_self = make_connection(ip => $nat_ip, direction => DIR_IN, port => 50004);
is(recv_version($conn_self, nonce => QBitcoin::Protocol::my_nonce()), -1, "self-connection rejected");
ok(!$conn_self->protocol->greeted, "self-connection is not greeted");
$conn_self->disconnect(); # as the network loop does after cmd_version failure

# Simultaneous mutual connect: both sides must keep the same connection,
# the tie-break depends only on the nonces (the lesser nonce is the caller)
my $peer_ip = ip4("198.51.100.20");
my $nonce_c = "CCCCCCCC";
my $conn_out = make_connection(ip => $peer_ip, direction => DIR_OUT, port => PORT);
my $conn_in  = make_connection(ip => $peer_ip, direction => DIR_IN,  port => 50005);
is(recv_version($conn_out, nonce => $nonce_c), 0, "outgoing connection greeted");
my $keep_out = QBitcoin::Protocol::my_nonce() lt $nonce_c; # we are the caller of the kept connection
if ($keep_out) {
    is(recv_version($conn_in, nonce => $nonce_c), -1, "mutual connect: incoming dropped by tie-break");
    is($conn_out->state, STATE_CONNECTED, "mutual connect: outgoing survives");
    ok($conn_in->protocol->greeted, "dropped duplicate is greeted (not a failed connect)");
    $conn_in->disconnect();
}
else {
    is(recv_version($conn_in, nonce => $nonce_c), 0, "mutual connect: incoming wins by tie-break");
    is($conn_out->state, STATE_DISCONNECTED, "mutual connect: outgoing dropped");
    is($conn_in->state, STATE_CONNECTED, "mutual connect: incoming survives");
}

# A reachability probe never displaces a working connection
my $probe_ip = ip4("198.51.100.21");
my $nonce_d = "DDDDDDDD";
my $conn_real = make_connection(ip => $probe_ip, direction => DIR_IN, port => 50006);
is(recv_version($conn_real, nonce => $nonce_d), 0, "incoming connection greeted");
my $conn_probe = make_connection(ip => $probe_ip, direction => DIR_OUT, port => PORT, probe => 1);
is(recv_version($conn_probe, nonce => $nonce_d), -1, "probe of an already connected node is dropped");
is($conn_real->state, STATE_CONNECTED, "working connection survives the probe");
ok(defined $conn_probe->peer->last_success_time, "probe still confirmed reachability");
$conn_probe->disconnect();

# Old nodes send no nonce: legacy single connection per IP
my $old_ip = ip4("192.0.2.30");
my $conn_old1 = make_connection(ip => $old_ip, direction => DIR_IN, port => 50007);
is(recv_version($conn_old1), 0, "old node (no nonce) greeted");
my $conn_old2 = make_connection(ip => $old_ip, direction => DIR_IN, port => 50008);
is(recv_version($conn_old2), -1, "second old connection from the same IP rejected");
is($conn_old1->state, STATE_CONNECTED, "first old connection stays alive");
$conn_old2->disconnect();

# But an old node behind the same NAT address as a new node is accepted
my $conn_old3 = make_connection(ip => $nat_ip, direction => DIR_IN, port => 50009);
is(recv_version($conn_old3), 0, "old node behind the same IP as new nodes greeted");
is($conn_a2->state, STATE_CONNECTED, "new node sessions are not affected");
is($conn_b->state, STATE_CONNECTED, "new node sessions are not affected");

done_testing();
