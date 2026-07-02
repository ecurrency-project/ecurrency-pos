package QBitcoin::Fork;
use warnings;
use strict;

# Process read-only RPC/REST requests in a forked child so that a long request
# (large address history, post-quantum signing, ...) does not block the main loop.
# fork() gives the child a copy-on-write snapshot of the whole in-memory state
# (block pool, mempool, TXO cache), so the child sees a consistent point-in-time
# view without any locking. The child handles exactly one request, writes the
# response and exits; connections have no keep-alive, so nothing is handed back.
# Requests that modify in-memory or database state are never forked and are
# processed in the main process as before.

use POSIX qw(WNOHANG);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::ORM ();
use QBitcoin::ConnectionList;

use constant MAX_FORK_CHILDREN => 8;

my @LISTEN_SOCKETS;
my %CHILDREN;
my $IS_CHILD = 0;

sub is_child { $IS_CHILD }

sub enabled {
    return $config->{fork_requests} // 1;
}

# The child must close its copies of the listening sockets, otherwise the port
# stays bound while the child is alive even if the parent exits
sub register_listen_socket {
    my $class = shift;
    push @LISTEN_SOCKETS, grep { defined } @_;
}

# Returns 0 in the parent: the connection now belongs to the child, the caller must not touch it.
# Returns 1 in the child: the caller processes the request as usual and must end with finish().
# Returns undef if the request was not forked and must be processed inline.
sub spawn {
    my $class = shift;
    my ($connection) = @_;

    enabled()
        or return undef;
    if (keys %CHILDREN >= ($config->{max_fork_children} // MAX_FORK_CHILDREN)) {
        Debugf("Too many forked request handlers (%u), process request inline", scalar keys %CHILDREN);
        return undef;
    }
    my $pid = fork();
    if (!defined $pid) {
        Warningf("Cannot fork request handler: %s, process request inline", $!);
        return undef;
    }
    if ($pid) {
        $CHILDREN{$pid} = 1;
        $connection->detach();
        return 0;
    }
    $IS_CHILD = 1;
    $SIG{TERM} = $SIG{INT} = 'DEFAULT';
    close($_) foreach @LISTEN_SOCKETS;
    foreach my $other (QBitcoin::ConnectionList->list) {
        next if $other == $connection;
        # Plain close of our copy of the descriptor; shutdown() would act on the shared
        # file description and break the parent's connection
        close($other->socket) if $other->socket;
    }
    # The inherited database handle belongs to the parent; drop it without disconnect
    # and let the first query in the child open a fresh connection
    QBitcoin::ORM::reset_dbh_after_fork();
    return 1;
}

# End of the request processing in the child: flush the response and exit
# without calling destructors or END blocks (they belong to the parent state)
sub finish {
    my $class = shift;
    my ($connection) = @_;

    # The accepted socket is blocking, so a plain syswrite loop flushes the rest of the response
    while ($connection->socket && length($connection->sendbuf)) {
        my $n = syswrite($connection->socket, $connection->sendbuf);
        if (!defined $n) {
            Warningf("Error write to socket: %s", $!);
            last;
        }
        $connection->sendbuf = substr($connection->sendbuf, $n);
    }
    $connection->disconnect() if $connection->socket;
    POSIX::_exit(0);
}

# Called periodically from the main loop; no global SIGCHLD handler to avoid
# surprising EINTR and waitpid interference elsewhere
sub reap {
    my $class = shift;
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        delete $CHILDREN{$pid};
    }
}

1;
