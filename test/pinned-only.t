#! /usr/bin/env perl
use warnings;
use strict;

# The "pinned-only" config option makes a (hidden, non-public) node talk only to the peers
# explicitly listed in the config:
# - outgoing connections are made only to pinned peers, never to learned or fallback peers
# - port 0 is advertised in the "version" message so remote nodes do not store or announce us
# - peer addresses received in "addr"/"vernak" or as a relayed object origin are not stored
# - "getaddr" is not sent after a greeting (learned addresses would never be dialed anyway)

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM; # in-memory sqlite, peers are stored in the database
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Protocol;
use QBitcoin::ProtocolState qw(btc_synced);
use QBitcoin::Network;

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
    my ($connection) = @_;
    my $payload = pack("VQ<Q<a26", 2, 0, time(), pack("Q<a16n", 0, $connection->peer->ip, 7000));
    $payload .= pack("Q<", ++$next_nonce);
    $connection->protocol->command("version");
    return $connection->protocol->cmd_version($payload);
}

sub sent_adv_port {
    my ($connection) = @_;
    # 24-byte message header, then version:4 features:8 time:8, then my_address: features:8 addr:16 port:2
    my (undef, undef, $adv_port) = unpack("Q<a16n", substr($connection->sendbuf, 24 + 20, 26));
    return $adv_port;
}

# Advertised port: the real listening port normally, 0 in pinned-only mode
$config->{port} = 12345;
my $conn_out = make_connection(direction => DIR_OUT);
$conn_out->protocol->startup();
is(sent_adv_port($conn_out), 12345, "listening port advertised without pinned-only");

$config->{pinned_only} = 1;
$conn_out = make_connection(direction => DIR_OUT);
$conn_out->protocol->startup();
is(sent_adv_port($conn_out), 0, "port 0 advertised in pinned-only mode");

# Peer addresses from an "addr" message are not stored in pinned-only mode
my $learned_ip = IPV6_V4_PREFIX . pack("C4", 198, 51, 100, 1);
my $conn = make_connection();
recv_version($conn) == 0 or BAIL_OUT("greeting failed");
$conn->protocol->command("addr");
is($conn->protocol->cmd_addr(pack("Ca16n", 1, $learned_ip, 7001)), 0, "addr message accepted in pinned-only mode");
ok(!(grep { $_->ip eq $learned_ip } QBitcoin::Peer->get_all(PROTOCOL_QBITCOIN)),
    "peer from addr message not stored in pinned-only mode");

# "getaddr" is not sent after a greeting in pinned-only mode (and is sent without it)
ok(index($conn->sendbuf, "getaddr") == -1, "getaddr not sent in pinned-only mode");
delete $config->{pinned_only};
$conn = make_connection();
recv_version($conn) == 0 or BAIL_OUT("greeting failed");
ok(index($conn->sendbuf, "getaddr") != -1, "getaddr sent without pinned-only");
$conn->protocol->command("addr");
is($conn->protocol->cmd_addr(pack("Ca16n", 1, $learned_ip, 7001)), 0, "addr message accepted without pinned-only");
ok((grep { $_->ip eq $learned_ip } QBitcoin::Peer->get_all(PROTOCOL_QBITCOIN)),
    "peer from addr message stored without pinned-only");

# Outgoing connections: only pinned peers are dialed in pinned-only mode.
# The peer learned from the addr message above is a dial candidate without pinned-only.
my $pinned_ip = IPV6_V4_PREFIX . pack("C4", 198, 51, 100, 2);
my $pinned = QBitcoin::Peer->get_or_create(ip => $pinned_ip, type_id => PROTOCOL_QBITCOIN, pinned => 1, port => 7002);
my @dialed;
{
    no warnings 'redefine';
    *QBitcoin::Network::connect_to = sub { push @dialed, $_[0]; return undef };
}
$config->{pinned_only} = 1;
QBitcoin::Network::call_qbt_peers();
ok(scalar(@dialed), "pinned peer dialed in pinned-only mode");
ok(!(grep { !$_->pinned } @dialed), "only pinned peers dialed in pinned-only mode");
delete $config->{pinned_only};
@dialed = ();
QBitcoin::Network::call_qbt_peers();
ok((grep { !$_->pinned } @dialed), "non-pinned peers dialed without pinned-only");

done_testing();
