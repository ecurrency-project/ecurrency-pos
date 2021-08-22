package QBitcoin::Log;
use warnings;
use strict;

use Exporter qw(import);
our @EXPORT = qw(Log);

use Sys::Syslog qw(:standard :macros);
use POSIX qw(strftime);
use Time::HiRes;
use QBitcoin::Config;

openlog('qbitcoin', 'nofatal,pid', LOG_LOCAL0) unless $ENV{LOG_STDOUT};

my %indent;

sub Logf {
    my ($prio, $format, @args) = @_;
    if ($config->{verbose}) {
        my $t = Time::HiRes::time();
        printf "%s.%03d %s$format\n", strftime("%F %T", localtime($t)), ($t-int($t)) * 1000, $indent{$prio}, @args;
    }
    my $log = $config->{log} // 'syslog';
    if ($log eq 'syslog') {
        syslog($prio, $format, @args);
    }
    else {
        open my $fh, '>>', $log
            or die "Can't open log file [$log]\n";
        my $t = Time::HiRes::time();
        printf $fh "%s.%03d %s$format\n", strftime("%F %T", localtime($t)), ($t-int($t)) * 1000, $indent{$prio}, @args;
        close $fh;
    }
}

sub Log {
    my ($prio, $line) = @_;

    defined($line) or die "Log line undefined";
    @_ == 2 or die "Extra params for Log: [$line]";
    Logf($prio, '%s', $line);
}

# generate functions Debug(), Debugf(), Info(), Infof(), ...
foreach my $level (reverse qw(debug info notice warning err crit)) {
    push @EXPORT, 'LOG_' . uc $level;
    my $func = ucfirst $level;
    my $funcf = $func . 'f';
    push @EXPORT, $func, $funcf;
    no strict 'refs';
    *$func = sub { Log($level, @_) };
    *$funcf = sub { Logf($level, @_) };
}
$indent{crit} = $indent{err} = "! ";
$indent{warning} = "* ";
$indent{notice} = "+ ";
$indent{info} = "- ";
$indent{debug} = "  ";

1;
