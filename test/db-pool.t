#!/usr/bin/env perl
use warnings;
use strict;

# Pool of pre-opened database connections lent to forked request handlers.
# Needs a running mysql/mariadb server; skipped if there is none available.

use FindBin '$Bin';
use lib "$Bin/../lib", "$Bin/lib";
use Test::More;
use POSIX ();
use Time::HiRes ();

use QBitcoin::Config;
use QBitcoin::ORM;

$config->{dbi} = "mysql";
my $dsn;
foreach my $try ("DBI:mysql:test", "DBI:mysql:mysql", "DBI:mysql:database=test;mysql_read_default_file=$ENV{HOME}/.my.cnf") {
    my $dbh = eval { DBI->connect($try, undef, undef, { PrintError => 0, RaiseError => 1 }) }
        or next;
    $dbh->disconnect();
    $dsn = $try;
    last;
}
$dsn
    or plan skip_all => "No mysql server available";
$config->{dsn} = $dsn;

plan tests => 30;

sub pool_idle {
    return (QBitcoin::ORM::db_pool_stats())[0];
}

sub pool_wanted {
    return (QBitcoin::ORM::db_pool_stats())[2];
}

# Fork a request handler the same way QBitcoin::Fork does, ask the child for the id of the
# server connection it used and the result of a query on it, and let it exit with $exit_code
# (non-zero emulates a child killed in the middle of a request). With $unfinished the child
# leaves a statement handle with unfetched rows, as after an error in the middle of a request.
sub run_child {
    my ($exit_code, $unfinished) = @_;

    my $entry = QBitcoin::ORM::db_pool_take();
    pipe(my $reader, my $writer)
        or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        close($reader);
        QBitcoin::ORM::reset_dbh_after_fork($entry);
        my ($conn_id, $answer) = eval {
            my $dbh = QBitcoin::ORM::dbh;
            if ($unfinished) {
                my $sth = $dbh->prepare("SELECT 1 UNION SELECT 2 UNION SELECT 3");
                $sth->execute();
                $sth->fetchrow_array(); # and leave the rest of the rows unfetched
            }
            $dbh->selectrow_array("SELECT CONNECTION_ID(), 6*7");
        };
        syswrite($writer, ($conn_id // 0) . ":" . ($answer // 0));
        close($writer);
        QBitcoin::ORM::disconnect_dbh();
        POSIX::_exit($exit_code // 0);
    }
    close($writer);
    QBitcoin::ORM::db_pool_loaned($entry, $pid) if $entry;
    my ($conn_id, $answer) = split(/:/, readline($reader) // "");
    close($reader);
    waitpid($pid, 0);
    QBitcoin::ORM::db_pool_returned($pid, $?);
    return { conn_id => $conn_id, answer => $answer, entry => $entry };
}

# The pool is empty until a request handler needs a connection
QBitcoin::ORM::db_pool_maintain(2);
is(pool_idle(), 0, "no connections are opened in advance");

my ($master_conn_id) = QBitcoin::ORM::dbh->selectrow_array("SELECT CONNECTION_ID()");
ok($master_conn_id, "master has its own connection");

# The first child does not find a free connection and opens its own, as without the pool
my $first = run_child();
ok(!$first->{entry}, "no pooled connection for the first child");
is($first->{answer}, 42, "child made a query in the forked process");
isnt($first->{conn_id}, $master_conn_id, "child did not use the master connection");
is(pool_wanted(), 1, "the missed connection is requested for the next child");
is(pool_idle(), 0, "and is not opened in the middle of the request");

QBitcoin::ORM::db_pool_maintain(2);
is(pool_idle(), 1, "connection pre-opened from the main loop");
is(pool_wanted(), 1, "only the requested connection is opened, not the whole pool");

my $second = run_child();
ok($second->{entry}, "child got a pooled connection");
is($second->{answer}, 42, "child made a query on the pooled connection");
isnt($second->{conn_id}, $master_conn_id, "child did not use the master connection");
is(pool_idle(), 1, "connection returned to the pool after the child exited");

# The same server connection is lent again, without reconnect
my $third = run_child();
is($third->{conn_id}, $second->{conn_id}, "the same connection is reused by the next child");

# A child which left a statement with unfetched rows (an error in the middle of a request)
# does not desync the connection: the whole result set is read from the socket on execute
run_child(0, "unfinished");
my $fourth = run_child();
is($fourth->{conn_id}, $second->{conn_id}, "the same connection after an unfinished query");
is($fourth->{answer}, 42, "the connection is still in sync");

# The master connection is still usable after lending and taking connections back
my ($master_conn_id2) = QBitcoin::ORM::dbh->selectrow_array("SELECT CONNECTION_ID()");
is($master_conn_id2, $master_conn_id, "master connection is untouched");

# A child which did not finish its request cleanly may leave the connection in the
# middle of a query, such connection must not be returned to the pool
my $killed = run_child(1);
is($killed->{conn_id}, $second->{conn_id}, "the pooled connection was lent to the failing child");
is(pool_idle(), 0, "connection of a failed child is dropped");

QBitcoin::ORM::db_pool_maintain(2);
is(pool_idle(), 1, "dropped connection is replaced in the pool");
my $fifth = run_child();
isnt($fifth->{conn_id}, $second->{conn_id}, "the new connection is a different one");

# Two requests at once: the second one finds no free connection while the first child
# is still holding the pooled one, so the pool needs one connection more
my $fake_pid = 999999;
my $lent = QBitcoin::ORM::db_pool_take();
QBitcoin::ORM::db_pool_loaned($lent, $fake_pid);
is(QBitcoin::ORM::db_pool_take(), undef, "no free connection while the pooled one is lent out");
is(pool_wanted(), 2, "the pool needs one connection more");
QBitcoin::ORM::db_pool_returned($fake_pid, 0);
QBitcoin::ORM::db_pool_maintain(2);
is(pool_idle(), 2, "the second connection is pre-opened");

# The server has closed all the pooled connections (restart, KILL, wait_timeout):
# the master notices it on the next keep-alive and reopens the whole pool
foreach my $entry (map { QBitcoin::ORM::db_pool_take() } 1 .. 2) {
    # the test asks the pooled connection for its id, the node itself never queries it
    my ($conn_id) = $entry->{dbh}->selectrow_array("SELECT CONNECTION_ID()");
    QBitcoin::ORM::dbh->do("KILL $conn_id");
    $entry->{checked} = 0; # as if the keep-alive interval has passed
    QBitcoin::ORM::db_pool_release($entry);
}
Time::HiRes::sleep(0.2); # let the server close the killed connections
QBitcoin::ORM::db_pool_maintain(2);
is(pool_idle(), 1, "dead connections are dropped and only one is opened per main loop pass");
QBitcoin::ORM::db_pool_maintain(2);
is(pool_idle(), 2, "the rest of the pool is opened on the next passes");

# Connections which were not needed for a long time are released, also one per pass
foreach my $entry (map { QBitcoin::ORM::db_pool_take() } 1 .. 2) {
    $entry->{used} = time() - QBitcoin::ORM::DB_POOL_IDLE_TIMEOUT() - 1;
    QBitcoin::ORM::db_pool_release($entry);
}
QBitcoin::ORM::db_pool_maintain(2);
is(pool_idle(), 1, "unused connection is released");
is(pool_wanted(), 1, "and is not opened again");
QBitcoin::ORM::db_pool_maintain(2);
is(pool_idle(), 0, "an idle node keeps no pooled connections");
is(pool_wanted(), 0, "and does not want any");

QBitcoin::ORM::db_pool_close();
