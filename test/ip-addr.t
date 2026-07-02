#!/usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib", "$Bin/lib";
use Test::More;

use Socket qw(inet_pton pack_sockaddr_in pack_sockaddr_in6 AF_INET AF_INET6);
use QBitcoin::Const;
use QBitcoin::IP qw(ip_str ip_port_str parse_addr_port sockaddr_to_ip_port pack_sockaddr_by_ip);
use QBitcoin::Peer;

my $V4  = IPV6_V4_PREFIX . inet_pton(AF_INET, "203.0.113.7");
my $V6  = inet_pton(AF_INET6, "2001:db8::1");
my $LO6 = inet_pton(AF_INET6, "::1");

# ip_str
is(ip_str($V4), "203.0.113.7", "ip_str ipv4-mapped");
is(ip_str($V6), "2001:db8::1", "ip_str ipv6");
is(ip_str($LO6), "::1", "ip_str ipv6 loopback");
is(ip_str(undef), undef, "ip_str undef");
is(ip_str("short"), undef, "ip_str wrong length");

# ip_port_str
is(ip_port_str($V4, 9555), "203.0.113.7:9555", "ip_port_str ipv4");
is(ip_port_str($V6, 9555), "[2001:db8::1]:9555", "ip_port_str ipv6 brackets");
is(ip_port_str($V6), "[2001:db8::1]", "ip_port_str without port");

# parse_addr_port
is_deeply([parse_addr_port("*")], ["*", undef], "parse *");
is_deeply([parse_addr_port("127.0.0.1")], ["127.0.0.1", undef], "parse v4 addr");
is_deeply([parse_addr_port("127.0.0.1:9555")], ["127.0.0.1", 9555], "parse v4 addr:port");
is_deeply([parse_addr_port("node.example.com:9555")], ["node.example.com", 9555], "parse host:port");
is_deeply([parse_addr_port("[2001:db8::1]:9555")], ["2001:db8::1", 9555], "parse bracketed v6 with port");
is_deeply([parse_addr_port("[2001:db8::1]")], ["2001:db8::1", undef], "parse bracketed v6");
is_deeply([parse_addr_port("2001:db8::1")], ["2001:db8::1", undef], "parse bare v6 literal");
is_deeply([parse_addr_port("::")], ["::", undef], "parse ::");

# sockaddr_to_ip_port round trip both families
my ($port4, $ip4) = sockaddr_to_ip_port(pack_sockaddr_in(1234, inet_pton(AF_INET, "203.0.113.7")));
is($port4, 1234, "sockaddr_to_ip_port v4 port");
is($ip4, $V4, "sockaddr_to_ip_port v4 mapped address");
my ($port6, $ip6) = sockaddr_to_ip_port(pack_sockaddr_in6(4321, $V6));
is($port6, 4321, "sockaddr_to_ip_port v6 port");
is($ip6, $V6, "sockaddr_to_ip_port v6 address");

# pack_sockaddr_by_ip is the inverse of sockaddr_to_ip_port
foreach my $case ([ $V4, 9555 ], [ $V6, 9555 ]) {
    my ($ip, $port) = @$case;
    my ($family, $sockaddr) = pack_sockaddr_by_ip($port, $ip);
    my ($port2, $ip2) = sockaddr_to_ip_port($sockaddr);
    is($port2, $port, "pack/unpack round trip port for " . ip_str($ip));
    is($ip2, $ip, "pack/unpack round trip address for " . ip_str($ip));
}

# Peer::id and is_public_ip on ipv6 peers
my $peer4 = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => $V4);
is($peer4->id, "203.0.113.7", "peer id ipv4");
ok(defined $peer4->ipv4, "peer->ipv4 for mapped address");
my $peer6 = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => $V6);
is($peer6->id, "2001:db8::1", "peer id ipv6");
is($peer6->ipv4, undef, "peer->ipv4 undef for ipv6");
ok(QBitcoin::Peer::is_public_ip($V6), "public ipv6");
ok(!QBitcoin::Peer::is_public_ip($LO6), "loopback ipv6 is not public");

done_testing();
