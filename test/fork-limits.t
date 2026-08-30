#!/usr/bin/env perl
use warnings;
use strict;

# The max_rpc_connections / max_rest_connections limits must count requests which are
# being processed in forked children: QBitcoin::Fork->spawn() detaches such connections
# from the ConnectionList, and QBitcoin::Fork->forked_requests() reports them per
# protocol type until the child is reaped (see the accept loop in QBitcoin::Network).

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use POSIX ();
use Time::HiRes ();
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Connection;
use QBitcoin::REST; # not loaded by QBitcoin::Connection itself
use QBitcoin::ConnectionList;
use QBitcoin::Fork;

plan tests => 12;

my $next_port = 40000;
sub make_connection {
    my ($type_id) = @_;
    return QBitcoin::Connection->new(
        type_id   => $type_id,
        state     => STATE_CONNECTED,
        host      => "127.0.0.1",
        ip        => "127.0.0.1",
        addr      => IPV6_V4_PREFIX . pack("C4", 127, 0, 0, 1),
        port      => $next_port++,
        direction => DIR_IN,
    );
}

# Fork the same way HTTP::receive does; the child exits at once instead of
# processing a request, the parent returns the spawn() result
sub spawn_child {
    my ($connection) = @_;
    my $res = QBitcoin::Fork->spawn($connection);
    POSIX::_exit(0) if $res;
    return $res;
}

sub reap_all {
    for (1 .. 200) {
        QBitcoin::Fork->reap();
        return if !QBitcoin::Fork->forked_requests(PROTOCOL_RPC)
               && !QBitcoin::Fork->forked_requests(PROTOCOL_REST);
        Time::HiRes::sleep(0.01);
    }
}

is(QBitcoin::Fork->forked_requests(PROTOCOL_RPC), 0, "no forked rpc requests initially");

my $rpc = make_connection(PROTOCOL_RPC);
is(spawn_child($rpc), 0, "rpc request forked");
is(scalar(grep { $_->type_id == PROTOCOL_RPC } QBitcoin::ConnectionList->list()), 0,
    "detached connection is not in the connection list");
is(QBitcoin::Fork->forked_requests(PROTOCOL_RPC), 1, "forked rpc request is counted");
is(QBitcoin::Fork->forked_requests(PROTOCOL_REST), 0, "and is not counted as rest");

my $rest = make_connection(PROTOCOL_REST);
is(spawn_child($rest), 0, "rest request forked");
is(QBitcoin::Fork->forked_requests(PROTOCOL_REST), 1, "forked rest request is counted");
is(QBitcoin::Fork->forked_requests(PROTOCOL_RPC), 1, "rpc count is unchanged");

reap_all();
is(QBitcoin::Fork->forked_requests(PROTOCOL_RPC), 0, "rpc count dropped after reap");
is(QBitcoin::Fork->forked_requests(PROTOCOL_REST), 0, "rest count dropped after reap");

# When the children limit is reached the request is processed inline
# and must not be counted as forked
$config->{max_fork_children} = 0;
my $inline = make_connection(PROTOCOL_RPC);
is(spawn_child($inline), undef, "request processed inline when children limit reached");
is(QBitcoin::Fork->forked_requests(PROTOCOL_RPC), 0, "inline request is not counted as forked");
