#! /usr/bin/env perl
use warnings;
use strict;

# The self-announced hostname in the "version" message:
# - we announce the name from the "hostname" config option (sanitized), empty if not set
# - the announced name of the peer is stored as an unverified claim and its DNS verification
#   is scheduled; re-checks are rate-limited by HOSTNAME_CHECK_PERIOD
# - a name matching the one the peer is configured by ("peer" option) is verified without
#   a DNS check: it was forward-confirmed when it was resolved
# - the background resolver (QBitcoin::Resolver) confirms the name if it resolves
#   to the peer's address

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Time::HiRes;
use Test::More;
use QBitcoin::Test::ORM; # in-memory sqlite, needed for peer persist() on incoming greeting
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::IP qw(host_to_ips);
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Protocol;
use QBitcoin::Resolver;
use QBitcoin::Fork;
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
        my_port   => 33333,
    );
}

my $next_nonce = 0;
sub recv_version {
    my ($connection, %args) = @_;
    my $payload = pack("VQ<Q<a26", QBitcoin::Protocol::PROTOCOL_VERSION, 0, time(),
        pack("Q<a16n", 0, $connection->peer->ip, $args{adv_port} // 7000));
    unless ($args{old_format}) {
        $payload .= pack("Q<", ++$next_nonce);
        $payload .= pack("C/a*", $args{software} // "/TestNode:1/");
        $payload .= pack("C/a*", $args{hostname}) if defined $args{hostname};
    }
    $connection->protocol->command("version");
    return $connection->protocol->cmd_version($payload);
}

# software and hostname fields of the sent "version" message
# (24-byte message header, then version:4 features:8 time:8 my_address:26 nonce:8)
sub sent_hostname {
    my ($connection) = @_;
    my (undef, $hostname) = unpack('@54 C/a* C/a*', substr($connection->sendbuf, 24));
    return $hostname;
}

# We announce the configured hostname, sanitized and truncated
$config->{hostname} = "node\x01.example.com" . "x" x 100;
my $conn_out = make_connection(direction => DIR_OUT);
$conn_out->protocol->startup();
is(sent_hostname($conn_out), substr("node.example.com" . "x" x 100, 0, HOSTNAME_MAX_LENGTH),
    "announced hostname sanitized and truncated");

# Without the config option an empty name is announced
delete $config->{hostname};
$conn_out = make_connection(direction => DIR_OUT);
$conn_out->protocol->startup();
is(sent_hostname($conn_out), "", "empty hostname announced when not configured");

# Handshake processing with the DNS verification mocked out
my @scheduled;
{
    no warnings 'redefine';
    local *QBitcoin::Resolver::verify_hostname = sub { push @scheduled, $_[1] };

    # The announced name is stored unverified and its verification is scheduled
    my $conn = make_connection();
    is(recv_version($conn, hostname => "peer1.example.com"), 0, "node with hostname greeted");
    my $peer = $conn->peer;
    is($peer->hostname, "peer1.example.com", "announced hostname stored");
    ok(!$peer->hostname_verified, "stored hostname is not verified yet");
    is_deeply(\@scheduled, [$peer], "hostname verification scheduled");

    # A fresh check result rate-limits re-checking, a stale one does not
    @scheduled = ();
    $peer->update(hostname_check_time => time());
    recv_version($conn, hostname => "peer1.example.com");
    is_deeply(\@scheduled, [], "recently checked hostname not re-checked");
    $peer->update(hostname_check_time => time() - HOSTNAME_CHECK_PERIOD - 1);
    recv_version($conn, hostname => "peer1.example.com");
    is_deeply(\@scheduled, [$peer], "stale hostname check repeated");

    # A changed name resets the verified flag and is re-checked immediately
    @scheduled = ();
    $peer->update(hostname_verified => 1, hostname_check_time => time());
    recv_version($conn, hostname => "peer2.example.com");
    is($peer->hostname, "peer2.example.com", "changed hostname stored");
    ok(!$peer->hostname_verified, "verified flag reset on hostname change");
    is_deeply(\@scheduled, [$peer], "changed hostname verification scheduled");

    # The received name is sanitized and truncated
    @scheduled = ();
    recv_version($conn, hostname => "peer\x02" . "y" x 100);
    is($peer->hostname, substr("peer" . "y" x 100, 0, HOSTNAME_MAX_LENGTH),
        "received hostname sanitized and truncated");

    # An explicitly announced empty name clears the stored one
    recv_version($conn, hostname => "");
    is($peer->hostname, undef, "hostname cleared on empty announcement");

    # No hostname field (an old node): the stored name is kept
    $peer->update(hostname => "peer3.example.com");
    recv_version($conn, old_format => 1);
    is($peer->hostname, "peer3.example.com", "stored hostname kept when the field is not sent");

    # A name matching the one the peer is configured by is verified without a DNS check
    @scheduled = ();
    my ($config_peer) = QBitcoin::Peer->get_or_create(host => "localhost", type_id => PROTOCOL_QBITCOIN);
    ok($config_peer, "peer created by a configured DNS name");
    is($config_peer->config_name, "localhost", "configured name remembered");
    is($config_peer->display_hostname, "localhost", "configured name displayed as a fallback");
    ok($config_peer->display_hostname_verified, "configured name displayed as verified");
    my $config_conn = make_connection(ip => $config_peer->ip);
    recv_version($config_conn, hostname => "localhost");
    ok($config_conn->peer->hostname_verified, "announced name matching the configured one verified");
    is_deeply(\@scheduled, [], "no DNS check for the name the peer is configured by");
}

# The real background resolver: wait for the forked child's verdict
sub wait_check {
    my ($peer) = @_;
    for (1 .. 200) {
        QBitcoin::Fork->reap();
        QBitcoin::Resolver->process();
        return 1 if defined $peer->hostname_check_time;
        Time::HiRes::sleep(0.05);
    }
    return 0;
}

my @localhost_ips = host_to_ips("localhost");
ok(@localhost_ips, "localhost resolves");

# The name resolves to the peer's address: verified
my $match_peer = QBitcoin::Peer->get_or_create(ip => $localhost_ips[0], type_id => PROTOCOL_QBITCOIN);
$match_peer->update(hostname => "localhost");
QBitcoin::Resolver->verify_hostname($match_peer);
ok(wait_check($match_peer), "matching hostname check completed");
ok($match_peer->hostname_verified, "hostname resolving to the peer address verified");

# The name resolves, but not to the peer's address: not verified
my $mismatch_peer = QBitcoin::Peer->get_or_create(ip => IPV6_V4_PREFIX . pack("C4", 192, 0, 2, 250), type_id => PROTOCOL_QBITCOIN);
$mismatch_peer->update(hostname => "localhost");
QBitcoin::Resolver->verify_hostname($mismatch_peer);
ok(wait_check($mismatch_peer), "mismatching hostname check completed");
ok(!$mismatch_peer->hostname_verified, "hostname resolving to a foreign address not verified");

# The name does not resolve (invalid syntax fails locally, no DNS query): not verified
my $bad_peer = QBitcoin::Peer->get_or_create(ip => IPV6_V4_PREFIX . pack("C4", 192, 0, 2, 251), type_id => PROTOCOL_QBITCOIN);
$bad_peer->update(hostname => "no..such..name");
QBitcoin::Resolver->verify_hostname($bad_peer);
ok(wait_check($bad_peer), "unresolvable hostname check completed");
ok(!$bad_peer->hostname_verified, "unresolvable hostname not verified");
ok(defined $bad_peer->hostname_check_time, "failed check timestamp stored for rate-limiting");

done_testing();
