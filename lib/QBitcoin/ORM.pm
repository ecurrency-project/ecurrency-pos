package QBitcoin::ORM;
use warnings;
use strict;

use DBI;
use QBitcoin::Config;
use QBitcoin::Log;

use constant DB_NAME => 'qecurrency';

use constant DB_TYPES => {
    NUMERIC   => 1,
    STRING    => 2,
    TIMESTAMP => 3,
    BINARY    => 4,
};
use constant DB_TYPES;

# Define this as constant but not configurable option b/c in this case "DEBUG_ORM && Debugf(...)" will be skipped at compile time
use constant DEBUG_ORM => 0;

use parent 'Exporter';
our @EXPORT_OK = qw(dbh find fetch create replace update delete delete_by IGNORE DEBUG_ORM for_log wal_checkpoint_truncate);
push @EXPORT_OK, keys %{&DB_TYPES};
our %EXPORT_TAGS = ( types => [ keys %{&DB_TYPES} ] );

use constant DB_OPTS => {
    PrintError => 0,
    AutoCommit => 1,
    RaiseError => 1,
};

use constant KEY_RE => qr/^[a-z][a-z0-9_]*\z/;

use constant IGNORE => \undef; # { key => IGNORE } may be used to override default check for "key" column

# Pre-opened connections for forked read-only request handlers (see QBitcoin::Fork).
# Opening a database connection (tcp connect, authentication handshake) costs more than
# the whole short request, so the master keeps a few spare connections open and lends one
# to each forked child; the child inherits it ready to use and never opens its own.
# The master itself never runs queries on the pooled connections, so a child gets a
# connection in a clean idle state. A connection is lent to at most one live child; when
# the child exits the master validates the connection and puts it back into the pool.
# The pool is not opened in advance in full: it grows by one connection each time a child
# had to open its own because the pool was empty, and shrinks back when a connection stays
# unused. So a node which gets no read-only requests keeps no spare connections at all,
# and a node which serves them keeps as many as its request rate needs, up to the limit.
# Connections are opened from the main loop and one per pass, never during the request
# processing: connect() blocks the single-threaded master, and a slow or unavailable
# database server would stall it on every request instead of once per retry period.
use constant DB_POOL_PING_INTERVAL => 60;  # sec, keep-alive/validation period, well below mysql wait_timeout
use constant DB_POOL_RETRY_TIME    => 10;  # sec, do not retry connect to an unavailable database too often
use constant DB_POOL_IDLE_TIMEOUT  => 300; # sec, release a connection which was not needed for this long

my $dbh;
my $dsn;
my @DB_POOL;   # idle pre-opened connections, [ { dbh => $handle, checked => $time, used => $time }, ... ]
my %DB_LOANED; # pid of a forked child => connection entry currently used by that child
my $POOL_WANTED = 0; # number of connections the observed request rate needs
my $POOL_RETRY_AT = 0;

sub dbh {
    return $dbh //= _connect();
}

sub _connect {
    my $dbi = $config->{dbi} // "mysql";
    my $db_name = $config->{database} // DB_NAME;
    my $location = "localhost";
    if (lc($dbi) eq "sqlite") {
        $dbi = "SQLite";
        $location = "";
        $db_name .= ".sqlite" unless $db_name =~ /\.sqlite$/;
    }
    elsif ($dbi eq "mysql") {
        $db_name .= ";mysql_read_default_file=$ENV{HOME}/.my.cnf";
    }
    if (!$dsn) {
        $dsn = $config->{"dsn"} // ("DBI:$dbi:$db_name" . ($location ? ":$location" : ""));
        Debugf("dsn: %s", $dsn);
    }
    my $login = $config->{"db.login"};
    my $password = $config->{"db.password"};
    my $handle = DBI->connect($dsn, $login, $password, DB_OPTS);
    if ($dbi eq "SQLite") {
        $handle->do("PRAGMA foreign_keys = ON");
        # WAL allows forked read-only request handlers to read while the main process writes
        $handle->do("PRAGMA journal_mode = WAL");
        $handle->do("PRAGMA busy_timeout = 5000");
        $handle->do("PRAGMA secure_delete = ON");
    };
    return $handle;
}

# Called in a forked child: the inherited handle shares the connection with the parent,
# so it must not be used and must not send a disconnect on DESTROY; drop it and use the
# connection lent by the master (if any), otherwise the next dbh() call opens a fresh one
sub reset_dbh_after_fork {
    my ($loaned) = @_;
    if ($dbh) {
        $dbh->{InactiveDestroy} = 1;
        undef $dbh;
    }
    # The whole pool belongs to the master; the child must not send a disconnect for any of
    # these connections, neither for those still idle in the pool nor for the one lent to it
    # (the master keeps it and lends it to the next child after this one exits)
    foreach my $entry (@DB_POOL, values %DB_LOANED, $loaned ? $loaned : ()) {
        $entry->{dbh}->{InactiveDestroy} = 1;
    }
    @DB_POOL = ();
    %DB_LOANED = ();
    $dbh = $loaned->{dbh} if $loaned;
    return;
}

sub _disconnect {
    my ($handle) = @_;
    return if $handle->{InactiveDestroy}; # inherited from the parent, not ours to close
    $handle->{Warn} = 0; # do not complain about statement handles still active
    eval { $handle->disconnect(); 1 }
        or Debugf("Error on database disconnect: %s", $@ =~ s/\s+$//r);
    return;
}

# Close the connection opened by this process, if any. Needed before POSIX::_exit()
# which skips destructors, otherwise the connection is dropped without COM_QUIT and
# the server logs "Aborted connection ... (Got an error reading communication packets)".
# A connection lent by the master is marked InactiveDestroy and is left open for reuse.
sub disconnect_dbh {
    my $handle = $dbh
        or return;
    undef $dbh;
    _disconnect($handle);
    return;
}

# Move all WAL content into the main database file and truncate the WAL file
sub wal_checkpoint_truncate {
    my $handle = dbh();
    return 1 if $handle->get_info(17) ne "SQLite";
    my ($busy, $log, $checkpointed) = $handle->selectrow_array("PRAGMA wal_checkpoint(TRUNCATE)");
    if ($busy) {
        # A concurrent reader (forked request handler) blocked the truncation
        Warningf("WAL file not truncated (%d of %d pages checkpointed), replaced data remains there until the next checkpoint cycle",
            $checkpointed, $log);
        return 0;
    }
    return 1;
}

# Pooling makes sense only for a connection to a database server; an SQLite connection is
# just an open file, it costs nothing to open and must not be carried across fork() at all
sub db_pool_enabled {
    return 0 if lc($config->{dbi} // "mysql") eq "sqlite";
    return 0 if ($config->{dsn} // "") =~ /^dbi:sqlite\b/i;
    return 1;
}

# Called from the main loop: open the connections the forked handlers were short of,
# keep the idle ones alive and release the ones which are not needed anymore
sub db_pool_maintain {
    my ($size) = @_;

    $size = 0 unless db_pool_enabled();
    $POOL_WANTED = $size if $POOL_WANTED > $size;
    my $time = time();
    @DB_POOL = grep { _pool_check($_, $time) } @DB_POOL;
    my $pool_size = @DB_POOL + keys %DB_LOANED;
    # Only one connection per call: the whole pool may need to be reopened at once
    # (the database server was restarted), and connecting is a blocking operation
    if ($pool_size < $POOL_WANTED && $POOL_RETRY_AT <= $time) {
        my $handle = eval { _connect() };
        if (!$handle) {
            Warningf("Cannot open pooled database connection: %s", $@ =~ s/\s+$//r);
            $POOL_RETRY_AT = $time + DB_POOL_RETRY_TIME;
            return;
        }
        Debugf("Opened pooled database connection %u of %u", ++$pool_size, $size);
        push @DB_POOL, { dbh => $handle, checked => $time, used => $time };
    }
    while ($pool_size > $POOL_WANTED && @DB_POOL) {
        # The limit was reduced by the config
        _disconnect(shift(@DB_POOL)->{dbh});
        $pool_size--;
    }
    # Connections are lent from the end of the pool, so the first one is the least recently
    # used; if even it was not needed for a long time then the pool is larger than necessary
    if (@DB_POOL && $POOL_WANTED > 0 && $DB_POOL[0]->{used} + DB_POOL_IDLE_TIMEOUT < $time) {
        Debugf("Release pooled database connection unused for %u sec", $time - $DB_POOL[0]->{used});
        _disconnect(shift(@DB_POOL)->{dbh});
        $POOL_WANTED--;
    }
    return;
}

sub _pool_check {
    my ($entry, $time) = @_;

    return 1 if $entry->{checked} + DB_POOL_PING_INTERVAL > $time;
    if (eval { $entry->{dbh}->ping }) {
        $entry->{checked} = $time;
        return 1;
    }
    Debugf("Pooled database connection is dead, drop it");
    _disconnect($entry->{dbh});
    return 0;
}

# Number of connections idle in the pool, lent to forked children and needed in total
sub db_pool_stats {
    return (scalar @DB_POOL, scalar keys %DB_LOANED, $POOL_WANTED);
}

# Called in the master right before fork(): reserve a connection for the child.
# Returns undef if the pool is empty, then the child opens its own connection as usual
# and the master pre-opens one more connection for the next request.
sub db_pool_take {
    my $entry = pop @DB_POOL # the most recently used one, let the spare ones age out
        or return _pool_missed();
    $entry->{used} = time();
    return $entry;
}

# The pool was empty, so all its connections are lent out and one more is needed than
# we have; count it as the new pool size (limited by the configured one in db_pool_maintain)
sub _pool_missed {
    my $needed = keys(%DB_LOANED) + 1;
    $POOL_WANTED = $needed if db_pool_enabled() && $POOL_WANTED < $needed;
    return undef;
}

# fork() succeeded, the connection is now in use by the child until it exits
sub db_pool_loaned {
    my ($entry, $pid) = @_;
    $DB_LOANED{$pid} = $entry;
    return;
}

# fork() failed, the reserved connection was not used by anyone
sub db_pool_release {
    my ($entry) = @_;
    push @DB_POOL, $entry;
    return;
}

# The forked child has exited, take its connection back. The child does not send COM_QUIT,
# so the connection is still alive (the master holds its own descriptor of the same socket)
# and, if the child finished its request normally, is idle and ready for the next one.
sub db_pool_returned {
    my ($pid, $status) = @_;

    my $entry = delete $DB_LOANED{$pid}
        or return;
    if ($status) {
        # Killed or died in the middle of a query: the connection may have an unread reply
        Debugf("Forked request handler exited with status %u, drop its database connection", $status);
        _disconnect($entry->{dbh});
        return;
    }
    $entry->{checked} = 0; # validate before lending it to the next child
    push @DB_POOL, $entry if _pool_check($entry, time());
    return;
}

# Called on shutdown, before global destruction disconnects the pooled handles:
# a COM_QUIT for a connection which is currently used by a forked child would break
# the request the child is processing, so such connections are only dropped
sub db_pool_close {
    _disconnect($_->{dbh}) foreach @DB_POOL;
    $_->{dbh}->{InactiveDestroy} = 1 foreach values %DB_LOANED;
    @DB_POOL = ();
    %DB_LOANED = ();
    return;
}

sub for_log {
    my ($data) = @_;
    defined($data) || return "undef";
    return $data =~ /^[[:print:]]*\z/s ? "'$data'" : "X'" . unpack("H*", $data) . "'";
}

sub parse_condition {
    my ($class, $key, $value, $values) = @_;
    my $condition = "";
    $key =~ KEY_RE
        or die "Incorrect search key [$key]";
    my $type = $class->FIELDS->{$key}
        or die "Unknown search key [$key] for " . $class->TABLE . "\n";
    if (ref $value eq 'ARRAY') {
        # "IN()" is sql syntax error, "IN(NULL)" matches nothing
        if ($type == TIMESTAMP) {
            $condition .= " `$key` IN (" . (@$value ? join(',', ('FROM_UNIXTIME(?)')x@$value) : "NULL") . ")";
            push @$values, @$value;
        }
        elsif ($type == BINARY) {
            $condition .= " `$key` IN (" . (@$value ? join(',', ('UNHEX(?)')x@$value) : "NULL") . ")";
            push @$values, map { unpack("H*", $_) } @$value;
        }
        else {
            $condition .= " `$key` IN (" . (@$value ? join(',', ('?')x@$value) : "NULL") . ")";
            push @$values, @$value;
        }
    }
    elsif (ref $value eq 'HASH') {
        my $first = 1;
        foreach my $op (keys %$value) {
            $condition .= " AND" unless $first;
            my $v = $value->{$op};
            if (ref $v eq 'SCALAR') {
                $condition .= "`$key` $op $$v ";
            }
            elsif (ref $v eq 'ARRAY') { # key => { NOT => [ 'value1', 'value2' ] }
                if ($type == TIMESTAMP) {
                    $condition .= " `$key` $op IN (" . (@$v ? join(',', ('FROM_UNIXTIME(?)')x@$v) : "NULL") . ")";
                    push @$values, @$v;
                }
                elsif ($type == BINARY) {
                    $condition .= " `$key` $op IN (" . (@$v ? join(',', ('UNHEX(?)')x@$v) : "NULL") . ")";
                    push @$values, map { unpack("H*", $_) } @$v;
                }
                else {
                    $condition .= " `$key` $op IN (" . (@$v ? join(',', ('?')x@$v) : "NULL") . ")";
                    push @$values, @$v;
                }
            }
            elsif (ref $v) {
                die "Incorrect search value type " . ref($v) . " key $key\n";
            }
            else {
                $condition .= " `$key` $op ?";
                push @$values, $v;
            }
            $first = 0;
        }
    }
    elsif (ref $value eq 'SCALAR') {
        $condition .= " `$key` = $$value" if defined $$value; # \undef is IGNORE
    }
    elsif (ref $value) {
        die "Incorrect search value type " . ref($value) . " key $key\n";
    }
    elsif (defined $value) {
        if ($type == TIMESTAMP) {
            $condition .= " `$key` = FROM_UNIXTIME(?)";
            push @$values, $value;
        }
        elsif ($type == BINARY) {
            $condition .= " `$key` = UNHEX(?)";
            push @$values, unpack("H*", $value);
        }
        else {
            $condition .= " `$key` = ?";
            push @$values, $value;
        }
    }
    else {
        $condition .= " `$key` IS NULL";
    }
    return $condition;
}

# Returns raw hashes, not objects, without pre_load(), on_load() and new()
sub fetch {
    my $class = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };

    my $table = $class->TABLE
        or die "No TABLE defined in $class\n";
    my $sql = "SELECT " .
        join(', ', map { $class->FIELDS->{$_} == TIMESTAMP ? "UNIX_TIMESTAMP(`$_`) AS `$_`" : "`$_`" } keys %{$class->FIELDS}) .
        " FROM `$table`";
    my @values;
    my $condition = '';
    my $sortby;
    my $limit;
    foreach my $key (keys %$args) {
        if ($key eq '-sortby') {
            $sortby = $args->{$key};
            next;
        }
        if ($key eq '-limit') {
            $limit = $args->{$key};
            next;
        }
        my $cond = parse_condition($class, $key, $args->{$key}, \@values);
        $condition .= " AND" if $condition;
        $condition .= $cond;
    }
    $sql .= " WHERE$condition"  if $condition;
    $sql .= " ORDER BY $sortby" if $sortby;
    $limit = 1 unless wantarray;
    $sql .= " LIMIT $limit" if $limit;
    DEBUG_ORM && Debugf("sql: [%s], values: [%s]", $sql, join(',', map { for_log($_) } @values));
    my $sth = dbh->prepare($sql);
    $sth->execute(@values);
    my @result;
    while (my $res = $sth->fetchrow_hashref()) {
        DEBUG_ORM && Debugf("orm: found {%s}", join(',', map { "'$_':" . (!defined($res->{$_}) ? "null" : $class->FIELDS->{$_} == BINARY ? for_log($res->{$_}) : $class->FIELDS->{$_} == NUMERIC ? $res->{$_} : "'$res->{$_}'") } sort keys %$res));
        push @result, $res;
    }
    DEBUG_ORM && Debugf("orm: found %u entries, errstr [%s]", scalar(@result), dbh->errstr // '');
    return @result;
}

sub find {
    my $class = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };

    my @result;
    my $fetch_func = $class->can('fetch') // \&fetch;
    foreach my $res ($fetch_func->($class, $args)) {
        $res = $class->pre_load($res) if $class->can('pre_load');
        my $item = $class->new($res);
        $item = $item->on_load if $class->can('on_load');
        push @result, $item;
    }
    return wantarray ? @result : $result[0];
}

sub create {
    my $self_or_class = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };

    my ($self, $class);
    if (ref($self_or_class)) {
        die "create() should not have params when called as object method\n" if %$args;
        $self = $self_or_class;
        $class = ref($self);
        $args = { map { $_ => $self->$_ } grep { $class->FIELDS->{$_} } keys %$self };
    }
    else {
        $class = $self_or_class;
    }

    my $table = $class->TABLE
        or die "No TABLE defined in $class\n";
    my @keys;
    my @placeholders;
    my @values;
    foreach my $key (keys %$args) {
        $key =~ KEY_RE
            or die "Incorrect key [$key]";
        push @keys, $key;
        my $type = $class->FIELDS->{$key};
        if ($type == TIMESTAMP) {
            push @placeholders, 'FROM_UNIXTIME(?)';
            push(@values, $args->{$key});
        }
        elsif ($type == BINARY) {
            # sqlite can store binary data as string and truncate trailing zeros, so we use UNHEX() for store as blob
            push @placeholders, 'UNHEX(?)';
            push @values, defined($args->{$key}) ? unpack("H*", $args->{$key}) : undef;
        }
        else {
            push @placeholders, "?";
            push @values, $args->{$key};
        }
    }
    my $sql = "INSERT INTO `$table` (" . join(',', map { "`$_`" } @keys) . ") VALUES (" . join(',', @placeholders) . ")";
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', map { for_log($_) } @values));
    my $res = dbh->do($sql, undef, @values);
    if ($res != 1) {
        die "Can't create object $table\n";
    }
    $self //= $class->new($args);
    if ($class->FIELDS->{id}) {
        my $id = dbh->last_insert_id();
        $self->{id} = $id;
        DEBUG_ORM && Debugf("orm: last_insert_id: %u", $id);
    }
    return $self;
}

sub replace {
    my $self = shift;

    my $class = ref($self);
    my $table = $class->TABLE
        or die "No TABLE defined in $class\n";
    my @keys;
    my @placeholders;
    my @values;
    foreach my $key (keys %{$class->FIELDS}) {
        $key =~ KEY_RE
            or die "Incorrect key [$key]";
        push @keys, $key;
        my $type = $class->FIELDS->{$key}
            or die "Unknown key [$key] for $table\n";
        if (!defined $self->$key) {
            push @placeholders, "?";
            push @values, undef;
        }
        elsif ($type == TIMESTAMP) {
            push @placeholders, "FROM_UNIXTIME(?)";
            push @values, $self->$key;
        }
        elsif ($type == BINARY) {
            push @placeholders, "UNHEX(?)";
            push @values, defined($self->$key) ? unpack("H*", $self->$key) : undef;
        }
        else {
            push @placeholders, "?";
            push @values, $self->$key;
        }
    }
    my $sql = "REPLACE INTO `" . $table . "` (" . join(',', map { "`$_`" } @keys) . ") VALUES (" . join(',', @placeholders) . ")";
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', map { for_log($_) } @values));
    dbh->do($sql, undef, @values);
    if ($class->FIELDS->{id} && !$self->id) {
        my $id = dbh->last_insert_id();
        $self->{id} = $id;
        DEBUG_ORM && Debugf("orm: last_insert_id: %u", $id);
    }
    return $self;
}

sub _pk_condition {
    my ($self, $values) = @_;

    my $sql;
    if ($self->can('PRIMARY_KEY')) {
        my @conditions;
        foreach my $key ($self->PRIMARY_KEY) {
            if ($self->FIELDS->{$key} == BINARY) {
                push @conditions, "`$key` = UNHEX(?)";
                push @$values, defined($self->$key) ? unpack("H*", $self->$key) : undef;
            }
            else {
                push @conditions, "`$key` = ?";
                push @$values, $self->$key;
            }
        }
        $sql = " WHERE " . join(" AND ", @conditions);
    }
    else {
        $sql = " WHERE `id` = ?";
        @$values = ($self->id);
    }
    return $sql;
}

sub update {
    my $self = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };

    return unless %$args;
    my $table = $self->TABLE
        or die "No TABLE defined in " . ref($self) . "\n";
    my $sql = "UPDATE `$table` SET ";
    my @values;
    my $count;
    foreach my $key (keys %$args) {
        $key =~ KEY_RE
            or die "Incorrect key [$key]";
        $sql .= ", " if $count++;
        my $value = $args->{$key};
        if (ref $value eq "SCALAR") {
            $sql .= "`$key` = $$value";
            $self->$key(undef); # unknown value
        }
        else {
            if ($self->FIELDS->{$key} == TIMESTAMP) {
                $sql .= "`$key` = FROM_UNIXTIME(?)";
                push @values, $args->{$key};
            }
            elsif ($self->FIELDS->{$key} == BINARY) {
                $sql .= "`$key` = UNHEX(?)";
                push @values, defined($args->{$key}) ? unpack("H*", $args->{$key}) : undef;
            }
            else {
                $sql .= "`$key` = ?";
                push @values, $args->{$key};
            }
            $self->$key($args->{$key});
        }
    }
    my @pk_values;
    $sql .= _pk_condition($self, \@pk_values);
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', map { for_log($_) } @values, @pk_values));
    dbh->do($sql, undef, @values, @pk_values);
}

sub delete {
    my $self = shift;

    my $table = $self->TABLE
        or die "No TABLE defined in " . ref($self) . "\n";
    my $sql = "DELETE FROM `$table`";
    my @pk_values;
    $sql .= _pk_condition($self, \@pk_values);
    if (grep { !defined } @pk_values) {
        die "Object primary key undefined on delete $table\n";
    }
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', @pk_values));
    my $res = dbh->do($sql, undef, @pk_values);
    if ($res != 1) {
        die "Can't delete $table\n";
    }
}

sub delete_by {
    my $class = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };

    my $table = $class->TABLE
        or die "No TABLE defined in $class\n";
    my $sql = "DELETE FROM `$table`";
    my @values;
    my $condition = '';
    foreach my $key (keys %$args) {
        my $cond = parse_condition($class, $key, $args->{$key}, \@values);
        $condition .= " AND" if $condition;
        $condition .= $cond;
    }
    $sql .= " WHERE$condition"  if $condition;
    DEBUG_ORM && Debugf("sql: [%s], values: [%s]", $sql, join(',', map { for_log($_) } @values));
    dbh->do($sql, undef, @values);
}

1;
