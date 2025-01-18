package QBitcoin::Test::ORM;
use warnings;
use strict;

use FindBin '$Bin';

use parent 'QBitcoin::ORM';
use QBitcoin::Config;
use QBitcoin::ORM qw(dbh);

our @EXPORT_OK = qw(dbh);

$config->{dbi} = "sqlite";
$config->{dsn} = "DBI:SQLite::memory:";

my $schema = "$Bin/../db/qecurrency.sql";

sub create_database {
    local $/ = undef;
    open my $fh, '<', $schema
        or die "Can't read $schema";
    my $sql_cmds = <$fh>;
    close($fh);
    my $dbh = dbh;
    foreach my $cmd (split(/;\s*(?:--.*?)?\n/s, $sql_cmds)) {
        $cmd =~ s/\\\n//gs;
        next unless $cmd =~ /\S/s;
        $cmd =~ s/\sAUTO_INCREMENT\s/ /s;
        $dbh->do($cmd)
            or die "SQL error in cmd[$cmd]: " . $dbh->errstr;
    }
}

create_database();

1;
