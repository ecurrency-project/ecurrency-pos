package QBitcoin::Log;
use warnings;
use strict;
use feature 'state';

use Exporter qw(import);
our @EXPORT = qw(Log);

use Sys::Syslog qw(:standard :macros);
use POSIX qw(strftime);
use Time::HiRes;
use QBitcoin::Config;

my @indent;
my %level_numeric;
my $loglevel;

$indent[&LOG_CRIT] = $indent[&LOG_ERR] = "! ";
$indent[&LOG_WARNING] = "* ";
$indent[&LOG_NOTICE] = "+ ";
$indent[&LOG_INFO] = "- ";
$indent[&LOG_DEBUG] = "  ";

sub init {
    $loglevel = $config->{loglevel} ?
        $level_numeric{$config->{loglevel}} // die "Incorrect loglevel [$config->{loglevel}]\n" :
        $config->{debug} ? LOG_DEBUG : LOG_INFO;
    if ($ENV{LOG_NULL}) {
        $loglevel = LOG_CRIT;
        $config->set(log => '/dev/null');
    }
    else {
        $config->set(log => 'syslog') unless defined $config->{log};
        if ($config->{log} eq 'syslog') {
            openlog('qecurrency', 'nofatal,pid', LOG_LOCAL0);
        }
    }
    $| = 1 unless $config->{daemonize};
}

sub Logf {
    my ($prio, $format, @args) = @_;
    init() unless defined($loglevel);
    if (($config->{verbose} && $prio < LOG_DEBUG) || $config->{debug}) {
        my $t = Time::HiRes::time();
        printf "%s.%03d %s$format\n", strftime("%F %T", localtime($t)), ($t-int($t)) * 1000, $indent[$prio], @args;
    }
    if ($prio <= $loglevel) {
        state $log = $config->{log};
        if ($log eq 'syslog') {
            state $syslog = openlog('qecurrency', 'nofatal,pid', LOG_LOCAL0); # call once before first syslog()
            syslog($prio, $format, @args);
        }
        else {
            open my $fh, '>>', $log
                or die "Can't open log file [$log]: $!\n";
            my $t = Time::HiRes::time();
            printf $fh "%s.%03d %s$format\n", strftime("%F %T", localtime($t)), ($t-int($t)) * 1000, $indent[$prio], @args;
            close $fh;
        }
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
    my $level_const = 'LOG_' . uc $level;
    push @EXPORT, $level_const;
    my $level_num = Sys::Syslog->$level_const;
    $level_numeric{$level} = $level_num;
    my $func = ucfirst $level;
    my $funcf = $func . 'f';
    push @EXPORT, $func, $funcf;
    no strict 'refs';
    *$func  = sub { Log ($level_num, @_) };
    *$funcf = sub { Logf($level_num, @_) };
}

1;
