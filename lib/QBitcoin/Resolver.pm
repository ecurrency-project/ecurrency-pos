package QBitcoin::Resolver;
use warnings;
use strict;

use POSIX ();
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Fork;
use QBitcoin::IP qw(host_to_ips);

use constant MAX_QUEUE_LENGTH => 16;

# Exit codes of the resolver child
use constant {
    RESOLVED_MATCH    => 0, # the name resolves to the peer's address
    RESOLVED_MISMATCH => 1, # the name resolves, but not to the peer's address
    RESOLVE_FAILED    => 2, # the name does not resolve
};

my @QUEUE;   # peers waiting for a free child slot
my %RUNNING; # pid => { peer => ..., deadline => ... }

sub verify_hostname {
    my $class = shift;
    my ($peer) = @_;
    return if grep { $_->{peer} == $peer } values %RUNNING;
    return if grep { $_ == $peer } @QUEUE;
    if (@QUEUE >= MAX_QUEUE_LENGTH) {
        # not an error: the check will be retried on the next greeting of the peer
        Debugf("Hostname check queue is full, skip check for peer %s", $peer->id);
        return;
    }
    push @QUEUE, $peer;
    $class->process();
}

sub process {
    my $class = shift;
    my $now = time();
    foreach my $pid (keys %RUNNING) {
        kill('KILL', $pid) if $RUNNING{$pid}->{deadline} <= $now;
    }
    while (@QUEUE && keys %RUNNING < MAX_RESOLVER_CHILDREN) {
        $class->start_check(shift @QUEUE);
    }
}

sub start_check {
    my $class = shift;
    my ($peer) = @_;
    my $hostname = $peer->hostname
        // return; # cleared while waiting in the queue
    my $pid = fork();
    if (!defined $pid) {
        Warningf("Cannot fork hostname resolver: %s", $!);
        return;
    }
    if ($pid) {
        $RUNNING{$pid} = { peer => $peer, deadline => time() + HOSTNAME_CHECK_TIMEOUT };
        QBitcoin::Fork->register_worker($pid, sub { $class->finish_check($pid, $_[0]) });
        return;
    }
    QBitcoin::Fork->worker_child_init();
    my @ips = host_to_ips($hostname);
    POSIX::_exit(RESOLVE_FAILED) if !@ips;
    POSIX::_exit((grep { $_ eq $peer->ip } @ips) ? RESOLVED_MATCH : RESOLVED_MISMATCH);
}

sub finish_check {
    my $class = shift;
    my ($pid, $status) = @_;
    my $check = delete $RUNNING{$pid}
        or return;
    my $peer = $check->{peer};
    my $exit_code = $status & 127 ? -1 : $status >> 8; # -1: killed on deadline or died
    my $result =
        $exit_code == RESOLVED_MATCH    ? "verified" :
        $exit_code == RESOLVED_MISMATCH ? "does not match the peer address" :
        $exit_code == RESOLVE_FAILED    ? "does not resolve" : "check timed out";
    Infof("Hostname \"%s\" of peer %s %s", $peer->hostname // "", $peer->id, $result);
    # check_time is set on failures too: an unconfirmed name is re-checked
    # not more often than once per HOSTNAME_CHECK_PERIOD
    if (defined $peer->hostname) {
        $peer->update($exit_code >= 0 ? (hostname_verified => $exit_code == RESOLVED_MATCH ? 1 : 0) : (), hostname_check_time => time());
    }
    $class->process(); # a child slot got free
}

1;
