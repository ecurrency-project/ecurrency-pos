#! /usr/bin/env perl
use warnings;
use strict;

# Brute-force limit for the wallet password: exponential per-source lockout
# (QBitcoin::Password::Throttle), the gates in RPC process_request,
# cmd_setwalletpassword and REST check_access, and reporting a failure from a
# forked read-only request handler to the master via the child exit status.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use HTTP::Request;
use HTTP::Response;
use HTTP::Headers;
use MIME::Base64 qw(encode_base64);
use Cpanel::JSON::XS;
use Time::HiRes ();
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC AF_INET6 inet_pton);
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Config;
use QBitcoin::Password;
use QBitcoin::Password::Throttle qw(throttle_key throttle_delay throttle_failure throttle_success);
use QBitcoin::RPC;
use QBitcoin::REST;
use QBitcoin::Fork;

$config->{regtest} = 1;

my $JSON = Cpanel::JSON::XS->new;

# Frozen time for deterministic lockout windows; advance $NOW to expire them
my $NOW = 1_000_000;
my $throttle_mock = Test::MockModule->new('QBitcoin::Password::Throttle');
$throttle_mock->mock('_now', sub { $NOW });
$throttle_mock->mock('Warningf', sub {}); # the failure log is not part of the contract

# Minimal connection for the HTTP protocol handlers: the throttle needs only
# the binary remote address (addr), the printable one (ip) for logging, and
# the socket handling and type_id used by QBitcoin::Fork
{
    package TestConnection;
    use QBitcoin::Accessors qw(mk_accessors);
    mk_accessors(qw(ip addr port socket sendbuf type_id));
    sub new { my $class = shift; return bless { sendbuf => "", port => 12345, @_ }, $class }
    sub detach { close($_[0]->{socket}) if $_[0]->{socket}; $_[0]->{socket} = undef }
    sub disconnect { close($_[0]->{socket}) if $_[0]->{socket}; $_[0]->{socket} = undef }
}

sub v4_addr {
    my ($ip) = @_;
    return IPV6_V4_PREFIX . pack("C4", split(/\./, $ip));
}

# --- The throttle itself ---

is(throttle_key("plain-key"), "plain-key", "a non-address key is used as is");
is(throttle_key(v4_addr("10.1.2.3")), pack("C4", 10, 1, 2, 3), "IPv4-mapped address is keyed by the 4 address bytes");
is(throttle_key(inet_pton(AF_INET6, "2001:db8:a:b::1")), throttle_key(inet_pton(AF_INET6, "2001:db8:a:b:dead::beef")),
    "IPv6 addresses in one /64 share the key");
isnt(throttle_key(inet_pton(AF_INET6, "2001:db8:a:b::1")), throttle_key(inet_pton(AF_INET6, "2001:db8:a:c::1")),
    "IPv6 addresses in different /64 do not");

is(throttle_delay("unit"), 0, "no delay without failures");
my @delays = map { throttle_failure("unit", "10.9.9.9") } 1 .. 12;
is_deeply(\@delays, [ 1, 2, 4, 8, 16, 32, 64, 128, 256, 600, 600, 600 ],
    "exponential backoff from 1 second, capped at 600");
is(throttle_delay("unit"), 600, "locked out for the full delay");
$NOW += 100;
is(throttle_delay("unit"), 500, "the delay counts down with time");
throttle_success("unit");
is(throttle_delay("unit"), 0, "success resets the failure history");

throttle_failure("forget", "10.9.9.9");
$NOW += 3601;
is(throttle_delay("forget"), 0, "failure history expires after FORGET_TIME");
is(throttle_failure("forget", "10.9.9.9"), 1, "and the next failure starts from scratch");

# Eviction: the oldest entry is dropped when the table is full
my $max_keys = QBitcoin::Password::Throttle::MAX_KEYS();
throttle_failure("evict-first", "10.9.9.9");
$NOW += 10;
throttle_failure("evict-$_", "10.9.9.9") foreach 1 .. $max_keys - 1;
$NOW += 10;
throttle_failure("evict-new", "10.9.9.9");
is(throttle_failure("evict-first", "10.9.9.9"), 1, "the oldest entry was evicted from the full table");
is(throttle_failure("evict-1", "10.9.9.9"), 2, "a newer entry survived the eviction");

# --- RPC gate (QBitcoin::RPC::process_request and cmd_setwalletpassword) ---

QBitcoin::Password->set_password("pass1");

my $rpc_sent;
my $rpc_mock = Test::MockModule->new('QBitcoin::RPC');
$rpc_mock->mock('send', sub { $rpc_sent = $_[1]; 0 });

sub rpc_request {
    my ($conn, $method, $params, %extra) = @_;
    my $body = $JSON->encode({ method => $method, params => $params, %extra });
    my $request = HTTP::Request->new(POST => "/", HTTP::Headers->new(Content_Type => "application/json"), $body);
    $rpc_sent = undef;
    my $rpc = bless { connection => $conn }, 'QBitcoin::RPC';
    $rpc->process_request($request);
    return $JSON->decode(HTTP::Response->parse($rpc_sent)->content);
}

my $conn_a = TestConnection->new(ip => "10.0.0.1", addr => v4_addr("10.0.0.1"));
my $key_a  = throttle_key($conn_a->addr);

my $res = rpc_request($conn_a, "walletunlock", []);
is($res->{error}{code}, ERR_WALLET_PASSWORD_REQUIRED, "walletunlock without a password asks for it");
is(throttle_delay($key_a), 0, "a request without a password is not counted");

$res = rpc_request($conn_a, "walletunlock", [], password => "bad1");
is($res->{error}{code}, ERR_WALLET_PASSWORD_INCORRECT, "wrong password is rejected");
like($res->{error}{message}, qr/^Incorrect wallet password/, "with the usual message");
is(throttle_delay($key_a), 1, "and locks the source out for 1 second");

$res = rpc_request($conn_a, "walletunlock", [], password => "pass1");
is($res->{error}{code}, ERR_WALLET_PASSWORD_INCORRECT, "the correct password is rejected while locked out");
like($res->{error}{message}, qr/Too many failed wallet password attempts/, "with the lockout message");

$NOW += 2;
$res = rpc_request($conn_a, "walletunlock", [], password => "pass1");
ok(!$res->{error}, "the correct password is accepted after the lockout expires");
like($res->{result}, qr/not encrypted/, "and the command was executed");
is(throttle_delay($key_a), 0, "success resets the counter");

$res = rpc_request($conn_a, "setwalletpassword", ["pass2"], password => "bad2");
is($res->{error}{code}, ERR_WALLET_PASSWORD_INCORRECT, "setwalletpassword with a wrong old password fails");
is(throttle_delay($key_a), 1, "and counts as a failed attempt");

$res = rpc_request($conn_a, "setwalletpassword", ["pass2"], password => "pass1");
like($res->{error}{message}, qr/Too many failed wallet password attempts/, "setwalletpassword is gated while locked out");
ok(QBitcoin::Password->check_password("pass1"), "the password was not changed while locked out");

$NOW += 2;
$res = rpc_request($conn_a, "setwalletpassword", ["pass2"], password => "pass1");
ok(!$res->{error}, "setwalletpassword succeeds after the lockout expires");
ok(QBitcoin::Password->check_password("pass2"), "the password was changed");
is(throttle_delay($key_a), 0, "and the counter is reset");

# --- REST gate (QBitcoin::REST::check_access) ---

my $rest_sent;
my $rest_mock = Test::MockModule->new('QBitcoin::REST');
$rest_mock->mock('send', sub { $rest_sent = $_[1]; 0 });

sub rest_access {
    my ($conn, $auth) = @_;
    my $request = HTTP::Request->new(GET => "/wallet/my_addresses");
    $request->header(Authorization => "Basic " . encode_base64("user:$auth", "")) if defined $auth;
    $rest_sent = undef;
    my $rest = bless { connection => $conn }, 'QBitcoin::REST';
    my $deny = $rest->check_access($request);
    return (defined($deny) ? HTTP::Response->parse($rest_sent) : undef, $rest);
}

my $conn_b = TestConnection->new(ip => "10.0.0.2", addr => v4_addr("10.0.0.2"));
my $key_b  = throttle_key($conn_b->addr);

my ($response) = rest_access($conn_b, undef);
is($response->code, 401, "REST without credentials gets the Basic auth challenge");
is(throttle_delay($key_b), 0, "and is not counted as a failure");

($response) = rest_access($conn_b, "nope");
is($response->code, 401, "REST with a wrong password is rejected");
is(throttle_delay($key_b), 1, "and locks the source out");

($response) = rest_access($conn_b, "pass2");
is($response->code, 429, "the correct password gets 429 while locked out");
is($response->header("Retry-After"), 1, "with the Retry-After header");
like($response->content, qr/Too many failed wallet password attempts/, "and the lockout message");

$NOW += 2;
(my $deny, my $rest) = rest_access($conn_b, "pass2");
is($deny, undef, "the correct password is accepted after the lockout expires");
is($rest->{auth_password}, "pass2", "and stashed for the handlers");
is(throttle_delay($key_b), 0, "success resets the counter");

# --- Failure in a forked read-only handler reaches the master via the exit status ---

{
    # The forked child must not touch the master's SQLite handle
    my $orm_mock = Test::MockModule->new('QBitcoin::ORM');
    $orm_mock->mock('db_pool_take', sub { undef });
    $orm_mock->mock('reset_dbh_after_fork', sub { 0 });
    $orm_mock->mock('disconnect_dbh', sub { 0 });

    my $addr_c = v4_addr("10.0.0.3");
    my $key_c  = throttle_key($addr_c);

    my $run_child = sub {
        my ($fail) = @_;
        socketpair(my $child_sock, my $parent_sock, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
            or die "socketpair: $!";
        my $conn = TestConnection->new(ip => "10.0.0.3", addr => $addr_c, socket => $child_sock, type_id => PROTOCOL_REST);
        my $spawned = QBitcoin::Fork->spawn($conn);
        die "fork request handler unavailable" unless defined $spawned;
        if ($spawned) {
            # We are the forked child: report the failure the same way
            # QBitcoin::HTTP::register_auth_failure does and exit as after a request
            QBitcoin::Fork->auth_failure if $fail;
            QBitcoin::Fork->finish($conn); # never returns
        }
        # Parent: spawn() detached our copy of the socket, EOF means the child closed its one
        sysread($parent_sock, my $buf, 1);
        close($parent_sock);
    };

    $run_child->(0); # a child with a successful password check reports nothing
    $run_child->(1); # a child with a failed check exits with EXIT_AUTH_FAILURE

    my $delay = 0;
    for (1 .. 100) {
        QBitcoin::Fork->reap;
        last if $delay = throttle_delay($key_c);
        Time::HiRes::sleep(0.05);
    }
    # Exactly one failure recorded: the clean child contributed nothing,
    # the failing one was registered by reap() from its exit status
    is($delay, 1, "a failure in a forked handler is recorded by the master on reap");
}

done_testing();
