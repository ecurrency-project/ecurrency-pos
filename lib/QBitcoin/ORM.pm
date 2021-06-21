package QBitcoin::ORM;
use warnings;
use strict;
use feature "state";

use DBI;
use QBitcoin::Config;
use QBitcoin::Log;

use constant DB_NAME => 'qbitcoin';

use constant DB_TYPES => {
    NUMERIC   => 1,
    STRING    => 2,
    TIMESTAMP => 3,
    BINARY    => 4,
};
use constant DB_TYPES;

use constant DEBUG_ORM => 1;
use constant BIN_UNHEX => 0; # does not work for sqlite

use parent 'Exporter';
our @EXPORT_OK = qw(dbh find create replace update delete IGNORE DEBUG_ORM);
push @EXPORT_OK, keys %{&DB_TYPES};
our %EXPORT_TAGS = ( types => [ keys %{&DB_TYPES} ] );

use constant DB_OPTS => {
    PrintError => 0,
    AutoCommit => 1,
    RaiseError => 1,
};

use constant KEY_RE => qr/^[a-z][a-z0-9_]*\z/;

use constant IGNORE => \undef; # { key => IGNORE } may be used to override default check for "key" column

sub dbh {
    state $dbh;
    return $dbh if $dbh;
    my $db_name = $config->{"database"} // DB_NAME;
    my $dsn = $config->{"dsn"} // "DBI:mysql:$db_name;mysql_read_default_file=$ENV{HOME}/my.cnf:localhost";
    my $login = $config->{"db.login"};
    my $password = $config->{"db.password"};
    return $dbh = DBI->connect($dsn, $login, $password, DB_OPTS);
}

sub find {
    my $class = shift;
    my $args = ref $_[0] ? $_[0] : { @_ };

    my $table = $class->TABLE
        or die "No TABLE defined in $class\n";
    my $sql = "SELECT " .
        join(', ', map { $class->FIELDS->{$_} == TIMESTAMP ? "UNIX_TIMESTAMP($_) AS $_" : $_ } keys %{$class->FIELDS}) .
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
        $key =~ KEY_RE
            or die "Incorrect search key [$key]";
        my $value = $args->{$key};
        my $type = $class->FIELDS->{$key}
            or die "Unknown search key [$key] for " . $class->TABLE . "\n";
        $condition .= " AND" if $condition;
        if (ref $value eq 'ARRAY') {
            # "IN()" is sql syntax error, "IN(NULL)" matches nothing
            if ($type == BINARY && BIN_UNHEX) {
                $condition .= " $key IN (" . (@$value ? join(',', ('UNHEX(?)')x@$value) : "NULL") . ")";
                push @values, map unpack("H*", $_), @$value;
            }
            else {
                $condition .= " $key IN (" . (@$value ? join(',', ('?')x@$value) : "NULL") . ")";
                push @values, @$value;
            }
        }
        elsif (ref $value eq 'HASH') {
            my $first = 1;
            foreach my $op (keys %$value) {
                $condition .= " AND" unless $first;
                my $v = $value->{$op};
                if (ref $v eq 'SCALAR') {
                    $condition .= "$key $op $$v ";
                }
                elsif (ref $v eq 'ARRAY') { # key => { not => [ 'value1', 'value2 ] }
                    if ($type == BINARY && BIN_UNHEX) {
                        $condition .= " $key $op IN (" . (@$value ? join(',', ('UNHEX(?)')x@$value) : "NULL") . ")";
                        push @values, map unpack("H*", $_), @$value;
                    }
                    else {
                        $condition .= " $key $op IN (" . (@$value ? join(',', ('?')x@$value) : "NULL") . ")";
                        push @values, @$value;
                    }
                }
                elsif (ref $v) {
                    die "Incorrect search value type " . ref($v) . " key $key\n";
                }
                else {
                    $condition .= " $key $op ?";
                    push @values, $v;
                }
                $first = 0;
            }
        }
        elsif (ref $value eq 'SCALAR') {
            $condition .= " $key = $$value" if defined $$value; # \undef is IGNORE
        }
        elsif (ref $value) {
            die "Incorrect search value type " . ref($value) . " key $key\n";
        }
        elsif (defined $value) {
            if ($type == TIMESTAMP) {
                $condition .= " $key = FROM_UNIXTIME(?)";
                push @values, $value;
            }
            if ($type == BINARY && BIN_UNHEX) {
                $condition .= " $key = UNHEX(?)";
                push @values, unpack("H*", $value);
            }
            else {
                $condition .= " $key = ?";
                push @values, $value;
            }
        }
        else {
            $condition .= " $key IS NULL";
        }
    }
    $sql .= " WHERE$condition"  if $condition;
    $sql .= " ORDER BY $sortby" if $sortby;
    $limit = 1 unless wantarray;
    $sql .= " LIMIT $limit" if $limit;
    DEBUG_ORM && Debugf("sql: [%s], values: [%s]", $sql, join(',', map { $_ // "undef" } @values));
    my $sth = dbh->prepare($sql);
    $sth->execute(@values);
    my @result;
    while (my $res = $sth->fetchrow_hashref()) {
        DEBUG_ORM && Debugf("orm: found {%s}", join(',', map { "'$_':" . (!defined($res->{$_}) ? "null" : $class->FIELDS->{$_} == BINARY ? "X'" . unpack("H*", $res->{$_}) . "'" : $class->FIELDS->{$_} == NUMERIC ? $res->{$_} : "'$res->{$_}'") } sort keys %$res));
        $res = $class->pre_load($res) if $class->can('pre_load');
        my $item = $class->new($res);
        $item = $item->on_load if $class->can('on_load');
        push @result, $item;
    }
    DEBUG_ORM && Debugf("orm: found %u entries, errstr [%s]", scalar(@result), dbh->errstr // '');
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
        elsif ($type == BINARY && BIN_UNHEX) {
            push @placeholders, "UNHEX(?)";
            push(@values, unpack("H*", $args->{$key}));
        }
        else {
            push @placeholders, "?";
            push @values, $args->{$key};
        }
    }
    my $sql = "INSERT INTO `$table` (" . join(',', @keys) . ") VALUES (" . join(',', @placeholders) . ")";
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', map { $_ // "undef" } @values));
    my $res = dbh->do($sql, undef, @values);
    if ($res != 1) {
        die "Can't create object $table\n";
    }
    $self //= $class->new($args);
    if ($class->FIELDS->{id}) {
        my ($id) = dbh->selectrow_array("SELECT LAST_INSERT_ID()");
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
        elsif ($type == BINARY && BIN_UNHEX) {
            push @placeholders, "UNHEX(?)";
            push @values, unpack("H*", $self->$key);
        }
        else {
            push @placeholders, "?";
            push @values, $self->$key;
        }
    }
    my $sql = "REPLACE INTO `" . $table . "` (" . join(',', @keys) . ") VALUES (" . join(',', @placeholders) . ")";
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', map { $_ // "undef" } @values));
    dbh->do($sql, undef, @values);
    if ($class->FIELDS->{id} && !$self->id) {
        my ($id) = dbh->selectrow_array("SELECT LAST_INSERT_ID()");
        $self->{id} = $id;
        DEBUG_ORM && Debugf("orm: last_insert_id: %u", $id);
    }
    return $self;
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
            $sql .= "$key = $$value";
        }
        else {
            if ($self->FIELDS->{$key} == TIMESTAMP) {
                $sql .= "$key = FROM_UNIXTIME(?)";
                push @values, $args->{$key};
            }
            elsif ($self->FIELDS->{$key} == BINARY && BIN_UNHEX) {
                $sql .= "$key = UNHEX(?)";
                push @values, unpack("H*", $args->{$key});
            }
            else {
                $sql .= "$key = ?";
                push @values, $args->{$key};
            }
        }
    }
    my @pk_values;
    if ($self->can('PRIMARY_KEY')) {
        $sql .= " WHERE " . join(" AND ", map { "$_ = ?" } $self->PRIMARY_KEY);
        @pk_values = map { $self->$_ } $self->PRIMARY_KEY;
    }
    else {
        $sql .= " WHERE id = ?";
        @pk_values = ($self->id);
    }
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', map { $_ // "undef" } @values, @pk_values));
    dbh->do($sql, undef, @values, @pk_values);
}

sub delete {
    my $self = shift;

    my $table = $self->TABLE
        or die "No TABLE defined in " . ref($self) . "\n";
    my $sql = "DELETE FROM `$table` ";
    my @pk_values;
    if ($self->can('PRIMARY_KEY')) {
        $sql .= "WHERE " . join(" AND ", map { "$_ = ?" } $self->PRIMARY_KEY);
        @pk_values = map { $self->$_ } $self->PRIMARY_KEY;
    }
    else {
        $sql .= "WHERE id = ?";
        @pk_values = ($self->id);
    }
    if (grep { !defined } @pk_values) {
        die "Object primary key undefined on delete $table\n";
    }
    DEBUG_ORM && Debugf("orm: [%s], values [%s]", $sql, join(',', @pk_values));
    my $res = dbh->do($sql, undef, @pk_values);
    if ($res != 1) {
        die "Can't delete $table\n";
    }
}

1;
