#! /usr/bin/env perl
use warnings;
use strict;

# Peer reputation decay and stale-peer expiry:
# - reputation decays exponentially, anchored at update_time; reads never compound the decay
# - moving update_time (the anchor) always stores the correspondingly decayed value
# - long-dead peers are probed at most once per PEER_PROBE_DEAD_PERIOD, while the regular
#   outgoing-connect backoff (is_connect_allowed) stays much shorter
# - peers with no activity for PEER_EXPIRE_PERIOD and fresh failed connects are expired

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM qw(dbh);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::ConnectionList;

use constant DECAY_TIME => QBitcoin::Peer::REPUTATION_DECAY_TIME;

my $next_ip = 0;
sub make_peer {
    my %args = @_;
    my $peer = QBitcoin::Peer->get_or_create(
        ip      => IPV6_V4_PREFIX . pack("C4", 192, 0, 2, ++$next_ip),
        type_id => PROTOCOL_QBITCOIN,
    );
    $peer->update(%args) if %args;
    return $peer;
}

my $now = time();

# Exponential decay anchored at update_time
my $peer = make_peer(update_time => $now - DECAY_TIME, reputation => 100);
ok(abs($peer->reputation - 100 * exp(-1)) < 0.1, "reputation decays e times over the decay period");
my $r1 = $peer->reputation;
my $r2 = $peer->reputation;
ok(abs($r1 - $r2) < 1e-3, "repeated reads do not compound the decay");

# add_reputation decays the old value and moves the anchor
$peer = make_peer(update_time => $now - DECAY_TIME, reputation => 100);
$peer->add_reputation(1);
ok(abs($peer->{reputation} - (100 * exp(-1) + 1)) < 0.1, "add_reputation applies the pending decay first");
ok($peer->update_time >= $now, "add_reputation moves the decay anchor");
ok(abs($peer->reputation - $peer->{reputation}) < 1e-3, "no decay right after the anchor moved");

# Bumping update_time alone must not cancel the pending decay
$peer = make_peer(update_time => $now - DECAY_TIME, reputation => 100);
$peer->update(update_time => time());
ok(abs($peer->{reputation} - 100 * exp(-1)) < 0.1, "pending decay is stored when the anchor moves");

# Probe cadence for a long-dead peer
my $dead = make_peer(failed_connects => 10, last_fail_time => $now - 4*3600);
ok($dead->is_connect_allowed, "regular outgoing connect backoff stays short for a long-dead peer");
ok(!$dead->need_probe($now), "long-dead peer is not probed more often than once per day");
$dead->update(last_fail_time => $now - PEER_PROBE_DEAD_PERIOD - 3600);
ok($dead->need_probe($now), "long-dead peer is probed again after a day");
my $few_fails = make_peer(failed_connects => PEER_EXPIRE_MIN_FAILS, last_fail_time => $now - 3600);
ok($few_fails->need_probe($now), "peer with few failures keeps the short probe backoff");

# Expiry of long-inactive unreachable peers
my $old_time = $now - PEER_EXPIRE_PERIOD - 24*3600;
my %stale = (create_time => $old_time, update_time => $old_time, failed_connects => PEER_EXPIRE_MIN_FAILS, last_fail_time => $now - 3600);
my $expired = make_peer(%stale);
ok($expired->is_expired($now), "long-inactive unreachable peer is expired");
ok(!make_peer()->is_expired($now), "fresh peer is not expired");
ok(!make_peer(%stale, pinned => 1)->is_expired($now), "pinned peer is not expired");
ok(!make_peer(%stale, hidden => 1)->is_expired($now), "hidden peer is not expired");
ok(!make_peer(%stale, failed_connects => PEER_EXPIRE_MIN_FAILS - 1)->is_expired($now), "not expired without enough failed connects");
ok(!make_peer(%stale, update_time => $now - 3600, reputation => 1)->is_expired($now), "recently active peer is not expired");
ok(!make_peer(%stale, last_success_time => $now - 3600)->is_expired($now), "recently reachable peer is not expired");
ok(!make_peer(%stale, last_fail_time => $old_time - 10)->is_expired($now), "not expired without a failed connect after the last activity");

# remove() deletes the peer from the registry and from the database
my ($count_before) = dbh->selectrow_array("SELECT COUNT(*) FROM peer");
$expired->remove();
my ($count_after) = dbh->selectrow_array("SELECT COUNT(*) FROM peer");
is($count_after, $count_before - 1, "peer row deleted from the database");
ok(!(grep { $_->ip eq $expired->ip } QBitcoin::Peer->get_all(PROTOCOL_QBITCOIN)), "peer removed from the in-memory registry");

done_testing();
