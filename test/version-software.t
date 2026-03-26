#! /usr/bin/env perl
use warnings;
use strict;

# Software name and version in the "version" message:
# - sent as optional trailing field (1-byte length + string) after the session nonce
# - stored in the peer record, sanitized to printable ascii
# - old/short "version" payloads without the field still work

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM; # in-memory sqlite, needed for peer persist() on incoming greeting
use QBitcoin::Const;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Protocol;
use QBitcoin::ProtocolState qw(btc_synced);

btc_synced(1); # do not request btc blocks on greeting

my $next_ip = 0;
sub make_connection {
    my $peer = QBitcoin::Peer->get_or_create(
        ip        => IPV6_V4_PREFIX . pack("C4", 192, 0, 2, ++$next_ip),
        type_id   => PROTOCOL_QBITCOIN,
        transient => 1,
    );
    return QBitcoin::Connection->new(
        peer      => $peer,
        state     => STATE_CONNECTED,
        direction => DIR_IN,
        port      => 50000 + $next_ip,
        my_addr   => IPV6_V4_PREFIX . pack("C4", 127, 0, 0, 1),
        my_port   => PORT,
    );
}

my $next_nonce = 0;
sub recv_version {
    my ($connection, %args) = @_;
    my $payload = pack("VQ<Q<a26", 1, 0, time(), pack("Q<a16n", 0, $connection->peer->ip, PORT));
    $payload .= $args{nonce} // pack("Q<", ++$next_nonce) unless $args{old_format};
    $payload .= $args{raw_software} // pack("C/a*", $args{software}) if defined($args{software}) || defined($args{raw_software});
    $connection->protocol->command("version");
    return $connection->protocol->cmd_version($payload);
}

# Our own "version" message advertises the software
my $conn_out = make_connection();
$conn_out->protocol->startup();
my $sent = substr($conn_out->sendbuf, 24); # skip the message header
is(substr($sent, 0, 4), pack("V", 2), "version message sent");
my ($sent_software) = unpack("C/a*", substr($sent, 20 + 26 + 8));
is($sent_software, QBitcoin::Protocol::SOFTWARE, "version message contains our software id");
like($sent_software, qr(^/QECurrencyCore:\Q${\VERSION}\E/$), "software id is BIP14-like name:version");

# Software from the peer is stored in the peer record
my $conn = make_connection();
is(recv_version($conn, software => "/QECurrencyCore:9.9/"), 0, "version with software greeted");
is($conn->peer->software, "/QECurrencyCore:9.9/", "peer software stored");

# Non-printable characters are stripped before logging / storing
$conn = make_connection();
is(recv_version($conn, software => "/Evil\x00:1.0\x1b[31m/\x{ff}"), 0, "version with binary junk greeted");
is($conn->peer->software, "/Evil:1.0[31m/", "software sanitized to printable ascii");

# No software field (nonce only, previous protocol revision)
$conn = make_connection();
is(recv_version($conn), 0, "version without software greeted");
is($conn->peer->software, undef, "no software stored");

# Truncated software field is ignored
$conn = make_connection();
is(recv_version($conn, raw_software => pack("C", 20) . "short"), 0, "version with truncated software greeted");
is($conn->peer->software, undef, "truncated software ignored");

# Old format: no nonce, no software
$conn = make_connection();
is(recv_version($conn, old_format => 1), 0, "old version format greeted");
ok($conn->protocol->greeted, "old node greeted");
is($conn->peer->software, undef, "no software for old node");

done_testing();
