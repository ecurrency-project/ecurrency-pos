package QBitcoin::ORM::Transaction;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::ORM qw(dbh mark_db_failed DEBUG_ORM);

my $SQL_TRANSACTION;

sub new {
    my $class = shift;
    die "Nested sql transactions\n" if $SQL_TRANSACTION;
    DEBUG_ORM && Debug("Start sql transaction");
    $SQL_TRANSACTION = 1;
    dbh->begin_work;
    return bless {}, $class; # just guard object
}

sub commit {
    my $self = shift;
    die "commit without sql transaction\n" unless $SQL_TRANSACTION;
    dbh->commit;
    DEBUG_ORM && Debug("Commit sql transaction");
    undef $SQL_TRANSACTION;
}

sub rollback {
    my $self = shift;
    die "rollback without sql transaction\n" unless $SQL_TRANSACTION;
    if (defined(my $error = _rollback())) {
        die "$error\n";
    }
    DEBUG_ORM && Debug("Rollback sql transaction");
}

sub DESTROY {
    my $self = shift;
    if ($SQL_TRANSACTION) {
        Err("Destroy sql transaction without commit");
        # An exception raised inside the transaction may be propagating right now, and a die
        # in a destructor would be swallowed anyway; the failure is recorded by _rollback()
        _rollback();
    }
}

sub _rollback {
    undef $SQL_TRANSACTION; # closed for us either way, never report "nested transaction" after a failure
    eval { dbh->rollback; 1 }
        and return undef;
    my $error = $@ =~ s/\s+$//r;
    Critf("Cannot rollback sql transaction: %s", $error);
    mark_db_failed($error);
    return $error;
}

1;
