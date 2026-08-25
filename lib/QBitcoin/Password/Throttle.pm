package QBitcoin::Password::Throttle;
use warnings;
use strict;

# Brute-force protection for the wallet password: per-source failure counters
# with exponential backoff, kept in the master process memory. While a source
# is locked out its requests are rejected before the expensive PBKDF2 check,
# so a password flood cannot saturate the node either. A failure detected in a
# forked read-only request handler cannot update these counters directly (the
# child works on a copy-on-write snapshot); it is reported to the master via
# the child exit status instead, see QBitcoin::Fork.

use Exporter qw(import);
our @EXPORT_OK = qw(
    throttle_key
    throttle_delay
    throttle_failure
    throttle_success
    throttle_message
);

use QBitcoin::Const;
use QBitcoin::Log;

use constant {
    BASE_DELAY  => 1,    # seconds of lockout after the first failure, doubled by each next one
    MAX_DELAY   => 600,  # cap for the exponential backoff
    FORGET_TIME => 3600, # drop the failure history this long after the last failure
    MAX_KEYS    => 4096, # bound the memory an address-rotating attacker can consume
};

# $FAILED{$key} = { count => failures in a row, last => last failure time, until => locked until }
my %FAILED;

sub _now { time() }

# Key for the failure counter: an IPv4 address (stored IPv6-mapped) as its 4
# address bytes; a real IPv6 address by its /64 prefix - a host usually has a
# whole /64, so rotating addresses within it must not evade the limit
sub throttle_key {
    my ($addr) = @_;
    length($addr) == 16
        or return $addr;
    return substr($addr, 0, length(IPV6_V4_PREFIX)) eq IPV6_V4_PREFIX
        ? substr($addr, length(IPV6_V4_PREFIX))
        : substr($addr, 0, 8);
}

# Seconds until the next password attempt from this source is allowed, 0 if it
# is not locked out. Only reads the state, so it is safe in a forked child too
# (on the snapshot inherited from the master)
sub throttle_delay {
    my ($key) = @_;
    my $entry = $FAILED{$key}
        or return 0;
    my $time = _now();
    if ($time - $entry->{last} > FORGET_TIME) {
        delete $FAILED{$key};
        return 0;
    }
    return $entry->{until} > $time ? $entry->{until} - $time : 0;
}

# Register a failed password attempt and extend the lockout; $ip is the
# printable source address, used only for logging
sub throttle_failure {
    my ($key, $ip) = @_;
    my $time = _now();
    my $entry = $FAILED{$key};
    if (!$entry || $time - $entry->{last} > FORGET_TIME) {
        _make_room($time);
        $entry = $FAILED{$key} = { count => 0 };
    }
    my $count = ++$entry->{count};
    my $delay = $count >= 10 ? MAX_DELAY : BASE_DELAY << ($count - 1);
    $entry->{last}  = $time;
    $entry->{until} = $time + $delay;
    Warningf("Incorrect wallet password from %s: %u failed attempts, next attempt allowed in %u seconds",
        $ip, $count, $delay);
    return $delay;
}

# Reset the failure history after a successful password check
sub throttle_success {
    my ($key) = @_;
    delete $FAILED{$key};
    return;
}

sub throttle_message {
    my ($delay) = @_;
    return "Too many failed wallet password attempts, next attempt allowed in $delay seconds";
}

# The table is full: drop the expired entries, then the oldest ones if still needed
sub _make_room {
    my ($time) = @_;
    keys(%FAILED) >= MAX_KEYS
        or return;
    delete @FAILED{ grep { $time - $FAILED{$_}{last} > FORGET_TIME } keys %FAILED };
    my $extra = keys(%FAILED) - MAX_KEYS + 1;
    if ($extra > 0) {
        delete @FAILED{ (sort { $FAILED{$a}{last} <=> $FAILED{$b}{last} } keys %FAILED)[0 .. $extra - 1] };
    }
    return;
}

1;
