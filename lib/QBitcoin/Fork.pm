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

sub max_children {
    return $config->{max_fork_children} // MAX_FORK_CHILDREN;
}

# One pre-opened database connection per possible child, so that a forked handler
# never has to open its own; see the pool description in QBitcoin::ORM
sub db_pool_size {
    return $config->{db_pool_size} // max_children();
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
    if (keys %CHILDREN >= max_children()) {
        Debugf("Too many forked request handlers (%u), process request inline", scalar keys %CHILDREN);
        return undef;
    }
    # Reserve the connection before fork(): the master must know which one belongs to the child
    my $db_entry = QBitcoin::ORM::db_pool_take();
    my $pid = fork();
    if (!defined $pid) {
        Warningf("Cannot fork request handler: %s, process request inline", $!);
        QBitcoin::ORM::db_pool_release($db_entry) if $db_entry;
        return undef;
    }
    if ($pid) {
        QBitcoin::ORM::db_pool_loaned($db_entry, $pid) if $db_entry;
        $CHILDREN{$pid} = 1;
        $connection->detach();
        $class->register_worker($pid, \&QBitcoin::ORM::db_pool_returned);
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
    # and use the connection lent to us from the master's pool (if there was a free one,
    # otherwise the first query in the child opens a fresh connection)
    QBitcoin::ORM::reset_dbh_after_fork($db_entry);
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
    # _exit() skips destructors, so a database connection opened by this child must be
    # closed explicitly; otherwise the server logs an aborted connection. A connection
    # lent from the master's pool is marked InactiveDestroy and is left open: the master
    # keeps its own descriptor of the same socket, so closing ours on exit is invisible
    # to the server, and the master lends the connection to the next child
    QBitcoin::ORM::disconnect_dbh();
    POSIX::_exit(0);
}

my %WORKER_CALLBACKS;
sub register_worker {
    my $class = shift;
    my ($pid, $callback) = @_;
    $WORKER_CALLBACKS{$pid} = $callback;
}

sub worker_child_init {
    $IS_CHILD = 1;
    $SIG{TERM} = $SIG{INT} = 'DEFAULT';
    close($_) foreach @LISTEN_SOCKETS;
    # Plain close of our copies of the descriptors; shutdown() would act on the shared
    # file descriptions and break the parent's connections
    close($_->socket) foreach grep { $_->socket } QBitcoin::ConnectionList->list;
    QBitcoin::ORM::reset_dbh_after_fork();
}

# Called periodically from the main loop; no global SIGCHLD handler to avoid
# surprising EINTR and waitpid interference elsewhere
sub reap {
    my $class = shift;
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        delete $CHILDREN{$pid};
        if (my $callback = delete $WORKER_CALLBACKS{$pid}) {
            $callback->($pid, $?);
        }
    }
}

# Called from the main loop, never during the request processing: pre-open the database
# connections for the next requests, keep the open ones alive and release the extra ones
sub maintain_db_pool {
    my $class = shift;
    QBitcoin::ORM::db_pool_maintain(enabled() ? db_pool_size() : 0);
}

# Called on shutdown, while the pooled connections still may be in use by children
sub close_db_pool {
    my $class = shift;
    QBitcoin::ORM::db_pool_close();
}

1;
