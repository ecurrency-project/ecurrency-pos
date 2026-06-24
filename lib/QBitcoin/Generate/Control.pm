package QBitcoin::Generate::Control;
use warnings;
use strict;

use QBitcoin::Const;

my $GENERATED_TIME;
my $GENERATE_LEVEL;
my ($GEN_SLOT, $GEN_AT); # memoized randomized in-slot generation moment
my $START_SLOT;        # timeslot the node started generating in; never (re)stake it or earlier
my %PUBLISHED_STAKE;   # $timeslot => { $utxo_key => $stake_tx_hash } — stakes we have committed/published

sub generated_time {
    my $class = shift;
    $GENERATED_TIME = $_[0] if @_;
    return $GENERATED_TIME;
}

# Height of a block that filled a slot empty in our branch before the current timeslot.
# Set by QBitcoin::Block::Receive on a best-branch switch, consumed (and reset) by the
# next QBitcoin::Generate::generate() call, which tries to contest that block on weight.
sub generate_level {
    my $class = shift;
    $GENERATE_LEVEL = $_[0] if @_;
    return $GENERATE_LEVEL;
}

sub generate_new {
    my $class = shift;
    undef $GENERATED_TIME;
}

# The wall-clock moment within $timeslot at which we should produce our block. A fresh
# random delay BLOCK_INTERVAL*(1 - sqrt(rand)) after the slot start, chosen once per
# slot: small delays are most likely, the very end of the slot is very unlikely. The
# delay makes our timing unpredictable and lets us wait for peers' blocks / more
# transactions before committing our single per-slot stake. Local policy only, not
# consensus, so plain rand() is fine and the value must NOT be reproducible.
sub gen_time {
    my $class = shift;
    my ($timeslot) = @_;
    if (!defined($GEN_SLOT) || $GEN_SLOT != $timeslot) {
        $GEN_SLOT = $timeslot;
        my $delay = BLOCK_INTERVAL * (1 - sqrt(rand()));
        # keep strictly inside the slot so the block's timeslot stays $timeslot
        $delay = BLOCK_INTERVAL - 0.001 if $delay >= BLOCK_INTERVAL;
        $GEN_AT = $timeslot + $delay;
    }
    return $GEN_AT;
}

# The timeslot in which generation started. On restart the in-memory PUBLISHED_STAKE
# registry is empty, so we conservatively refuse to (re)stake the startup slot or any
# earlier one — we cannot prove we did not already publish a stake for them before the
# restart (and a clock moved backwards must not reopen them either).
sub start_slot {
    my $class = shift;
    $START_SLOT = $_[0] if @_;
    return $START_SLOT;
}

sub may_stake_slot {
    my $class = shift;
    my ($timeslot) = @_;
    return 1 if !defined $START_SLOT;
    return $timeslot > $START_SLOT;
}

# True if publishing $stake_tx for $timeslot would equivocate: one of its input UTXOs
# was already committed in a DIFFERENT stake for the same timeslot. Re-deriving the
# identical stake (same hash) is not a conflict.
sub staked_slot {
    my $class = shift;
    my ($timeslot) = @_;
    return exists $PUBLISHED_STAKE{$timeslot} ? 1 : 0;
}

# Have we already published a stake using this exact UTXO in this timeslot? Lets
# make_stake_tx skip published UTXOs and pick a still-free stake address for a sibling
# block in the same slot.
sub is_utxo_published {
    my $class = shift;
    my ($timeslot, $key) = @_;
    return $PUBLISHED_STAKE{$timeslot} && $PUBLISHED_STAKE{$timeslot}{$key} ? 1 : 0;
}

sub stake_conflicts {
    my $class = shift;
    my ($timeslot, $stake_tx) = @_;
    my $slot = $PUBLISHED_STAKE{$timeslot}
        or return 0;
    foreach my $in (@{$stake_tx->in}) {
        my $prev = $slot->{$in->{txo}->key}
            // next;
        return 1 if $prev ne $stake_tx->hash;
    }
    return 0;
}

# Record a stake we have committed to (its block entered our best branch, so the stake
# signature may have reached peers). Keeps us from ever signing a second, different
# stake for the same (timeslot, UTXO). Old slots beyond the slashing window are pruned.
sub record_stake {
    my $class = shift;
    my ($timeslot, $stake_tx) = @_;
    foreach my $in (@{$stake_tx->in}) {
        $PUBLISHED_STAKE{$timeslot}{$in->{txo}->key} = $stake_tx->hash;
    }
    my $cutoff = $timeslot - SLASHING_WINDOW * BLOCK_INTERVAL;
    foreach my $slot (keys %PUBLISHED_STAKE) {
        delete $PUBLISHED_STAKE{$slot} if $slot < $cutoff;
    }
}

1;
