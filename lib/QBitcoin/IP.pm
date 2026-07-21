package QBitcoin::IP;
use warnings;
use strict;

# Family-agnostic helpers for network addresses.
# Internally every address is a packed 16-byte IPv6 address; IPv4 is represented
# as IPv6-mapped: IPV6_V4_PREFIX . ipv4 (i.e. ::ffff:a.b.c.d).

use Exporter qw(import);
our @EXPORT_OK = qw(
    ip_str
    ip_port_str
    parse_addr_port
    sockaddr_to_ip_port
    pack_sockaddr_by_ip
    host_to_ips
);

use Socket qw(:DEFAULT getaddrinfo inet_ntop inet_pton pack_sockaddr_in6 unpack_sockaddr_in6 sockaddr_family AF_INET6 PF_INET6 SOCK_STREAM);
use QBitcoin::Const;

# Packed 16-byte address as text: dotted quad for IPv6-mapped IPv4, IPv6 literal otherwise
sub ip_str {
    my ($ip) = @_;
    defined($ip) && length($ip) == 16
        or return undef;
    substr($ip, 0, length(IPV6_V4_PREFIX)) eq IPV6_V4_PREFIX
        or return inet_ntop(AF_INET6, $ip);
    # copy: Socket before 2.041 does not apply get-magic, so the magical lvalue
    # returned by substr() would be seen as undef if passed to XS directly
    my $ip4 = substr($ip, length(IPV6_V4_PREFIX));
    return inet_ntop(AF_INET, $ip4);
}

# Text form for "addr:port" output; an IPv6 literal gets brackets: [2001:db8::1]:9555
sub ip_port_str {
    my ($ip, $port) = @_;
    my $str = ip_str($ip) // "unknown";
    $str = "[$str]" if index($str, ':') >= 0;
    return defined($port) ? "$str:$port" : $str;
}

# Parse a configured address specification into ($address, $port), port may be undef.
# Accepted forms: "*", "addr", "addr:port", "v6addr", "[v6addr]", "[v6addr]:port"
sub parse_addr_port {
    my ($str) = @_;
    defined($str)
        or return ();
    if ($str =~ /^\[([^\]]+)\](?::(\d+))?$/) {
        return ($1, $2);
    }
    my $colons = ($str =~ tr/:/:/);
    if ($colons == 1) {
        return split(/:/, $str);
    }
    # no colon: address only; more than one colon: bare IPv6 literal without port
    return ($str, undef);
}

# Unpack an accept()/getpeername()/getsockname() sockaddr of either family
# into ($port, 16-byte packed address)
sub sockaddr_to_ip_port {
    my ($sockaddr) = @_;
    if (sockaddr_family($sockaddr) == AF_INET6) {
        my ($port, $ip) = unpack_sockaddr_in6($sockaddr);
        return ($port, $ip);
    }
    my ($port, $ip4) = unpack_sockaddr_in($sockaddr);
    return ($port, IPV6_V4_PREFIX . $ip4);
}

# Resolve a hostname or an address literal into a list of unique packed 16-byte
# addresses (IPv4 as IPv6-mapped); empty list if the name cannot be resolved
sub host_to_ips {
    my ($host) = @_;
    my ($err, @res) = getaddrinfo($host, undef, { socktype => SOCK_STREAM });
    return () if $err;
    my %seen;
    return grep { !$seen{$_}++ }
        map { $_->{family} == AF_INET6 ?
            (unpack_sockaddr_in6($_->{addr}))[1] :
            IPV6_V4_PREFIX . (unpack_sockaddr_in($_->{addr}))[1] } @res;
}

# Build ($family, packed sockaddr) for connect()/bind() from a 16-byte packed address
sub pack_sockaddr_by_ip {
    my ($port, $ip) = @_;
    if (substr($ip, 0, length(IPV6_V4_PREFIX)) eq IPV6_V4_PREFIX) {
        # copy: Socket before 2.041 does not apply get-magic, so the magical lvalue
        # returned by substr() would be seen as undef if passed to XS directly
        my $ip4 = substr($ip, length(IPV6_V4_PREFIX));
        return (PF_INET, pack_sockaddr_in($port, $ip4));
    }
    return (PF_INET6, pack_sockaddr_in6($port, $ip));
}

1;
