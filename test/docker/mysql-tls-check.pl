#!/usr/bin/perl
# Check whether the mariadb client library can complete a handshake with a server which does not support TLS.
# mariadb-connector-c 3.4+ (alpine >= 3.23) requires TLS by default and refuses such a server,
# even over a unix socket; the Dockerfile sets MARIADB_TLS_DISABLE_PEER_VERIFICATION=1 as a workaround.
# A tiny fake server sends a protocol-v10 greeting without the CLIENT_SSL capability and answers
# the auth packet with "Access denied" (1045), so no real server is needed.
# Exit code: 0 - the client reached "Access denied", i.e. the handshake with a non-TLS server completed;
#            1 - the client refused the server with a TLS/SSL error; 2 - any other error.
use strict;
use warnings;
use IO::Socket::UNIX;
use DBI;

my $sock = "/tmp/fake-mysql.sock";
unlink $sock;
my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $sock, Listen => 1) or die "listen: $!";
my $pid = fork() // die "fork: $!";
if (!$pid) {
    alarm 10; # do not hang if the client never connects
    my $c = $srv->accept or exit 1;
    # LONG_PASSWORD | PROTOCOL_41 | SECURE_CONNECTION | PLUGIN_AUTH, no CLIENT_SSL (0x800)
    my $caps = 0x0001 | 0x0200 | 0x8000 | 0x80000;
    my $greeting = pack("C Z* V a8 x v C v v C x10 a13 Z*",
        10, "5.5.5-11.0.0-fake", 1, "12345678", $caps & 0xffff, 33, 2, $caps >> 16, 21, "123456789012\0", "mysql_native_password");
    $c->syswrite(pack("V", length($greeting)) . $greeting); # 3-byte length + seq 0
    $c->sysread(my $buf, 4); # client handshake response
    my $err = pack("C v a1 a5 a*", 0xff, 1045, "#", "28000", "Access denied for user");
    $c->syswrite(substr(pack("V", length($err)), 0, 3) . chr(2) . $err);
    close $c;
    exit 0;
}
close $srv;
my $dbh = DBI->connect("DBI:mysql:test;mysql_socket=$sock", "u", "p", { RaiseError => 0, PrintError => 0 });
kill 'TERM', $pid; # the client may have failed before connecting
waitpid($pid, 0);
unlink $sock;
my $err = $dbh ? "unexpected success" : $DBI::errstr;
my $env = $ENV{MARIADB_TLS_DISABLE_PEER_VERIFICATION} ? "with" : "without";
if ($err =~ /Access denied/) {
    print "mysql client handshake with a non-TLS server completed $env MARIADB_TLS_DISABLE_PEER_VERIFICATION\n";
    exit 0;
}
print "mysql client $env MARIADB_TLS_DISABLE_PEER_VERIFICATION: $err\n";
exit($err =~ /TLS|SSL/ ? 1 : 2);
