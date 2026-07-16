package QBitcoin::Slashing;
use warnings;
use strict;

# Slashing (nothing-at-stake penalty).
#
# A TX_TYPE_SLASHING transaction is trustless evidence that one validator signed two
# conflicting blocks with the SAME stake UTXO in the SAME timeslot (equivocation). It
# is not signed: any node that observes the two conflicting stakes can build it, and
# every node builds the byte-identical transaction from the same evidence.
#
# Evidence layout (placed right after tx_type in the transaction, like a downgrade
# payload), two proofs ordered by the stake-tx hash ascending:
#
#   proof  := prev_hash(32) . pack("N", timeslot) . digest(32) . varstr(stake_tx_bytes)
#   payload:= proof[0] . proof[1]
#
# prev_hash/timeslot/digest are exactly the three components of the block's
# Block::sign_data (the message the stake signed); stake_tx_bytes is the tx-level
# serialization of the stake (its inputs with signatures, and its outputs). From
# these the verifier reconstructs the signed message and checks the signature on the
# shared input(s) - the proof that the same key endorsed two different blocks.
#
# The slashing transaction then spends the shared (equivocated) UTXOs WITHOUT a
# signature and refunds each owner scripthash its value minus SLASHING_FINE; the fine
# becomes the transaction fee (into the reward fund). Refund outputs are plain outputs
# at the owner's scripthash and so are subject to the same STAKE_MATURITY spend lock as
# stake outputs (enforced for the spender in check_input_script).

use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::Crypto qw(hash160 hash256);
use QBitcoin::TXO;
use QBitcoin::Generate::Control;
use Bitcoin::Serialized qw(varint varstr);

use constant ATTR => qw(proofs);
mk_accessors(ATTR);

use constant PROOF_HEAD_LEN => 32 + 4 + 32; # prev_hash . timeslot . digest

# Watched stakes for equivocation detection. Retaining an entry here keeps the stake's
# evidence alive past the moment its block is dropped, which is exactly the retention
# the user asked for: stakes linger for SLASHING_WINDOW so a later conflicting stake can
# be caught. We store a fully detached SNAPSHOT (see _snapshot_stake), NOT the live
# QBitcoin::Transaction: a live transaction holds txo objects registered (weakened) in
# the global %TXO cache, and pinning any of them here would keep the weak entry alive
# after the block is dropped - so the unconditional save in Transaction::load_txo
# collides ("Attempt to override already loaded txo") when the corresponding
# transaction is received again. This applies to the stake's outputs AND to its inputs
# (an input is the previous stake's output). Indexed by timeslot then stake-UTXO key.
my %SEEN;       # $timeslot => { $utxo_key => snapshot QBitcoin::Transaction }
my $MAX_SLOT = 0;

# Stakes proven equivocated (we hold a slashing tx for them). A block whose stake
# spends one of these UTXOs in the banned timeslot is INVALID regardless of its branch
# weight - we never select such a branch and actively drop it if it is already best.
# This is the robust rule: it does not rely on out-weighing the equivocator.
my %BANNED;     # $utxo_key => { timeslot => $T, txo => $txo }

# --- (de)serialization -----------------------------------------------------

sub serialize {
    my $self = shift;
    my $data = "";
    foreach my $p (@{$self->proofs}) {
        $data .= $p->{prev_hash} . pack("N", $p->{timeslot}) . $p->{digest} . varstr($p->{raw});
    }
    return $data;
}

sub deserialize {
    my $class = shift;
    my ($data) = @_;
    my @proofs;
    for (1 .. 2) {
        my $head = $data->get(PROOF_HEAD_LEN) // return undef;
        my $raw  = $data->get_string() // return undef;
        push @proofs, {
            prev_hash => substr($head, 0, 32),
            timeslot  => unpack("N", substr($head, 32, 4)),
            digest    => substr($head, 36, 32),
            raw       => $raw,
        };
    }
    return $class->new(proofs => \@proofs);
}

# Database persistence in expanded (column) form rather than one opaque blob. The two
# proofs always share the same timeslot, so it is stored once.
sub stored_fields {
    my $self = shift;
    my ($p1, $p2) = @{$self->proofs};
    return {
        timeslot   => $p1->{timeslot},
        prev_hash1 => $p1->{prev_hash}, digest1 => $p1->{digest}, raw1 => $p1->{raw},
        prev_hash2 => $p2->{prev_hash}, digest2 => $p2->{digest}, raw2 => $p2->{raw},
    };
}

sub from_row {
    my $class = shift;
    my ($row) = @_;
    return $class->new(proofs => [
        { prev_hash => $row->prev_hash1, timeslot => $row->timeslot, digest => $row->digest1, raw => $row->raw1 },
        { prev_hash => $row->prev_hash2, timeslot => $row->timeslot, digest => $row->digest2, raw => $row->raw2 },
    ]);
}

# block_sign_data the stake signed, reassembled from a proof
sub _block_sign_data {
    my ($p) = @_;
    return $p->{prev_hash} . pack("N", $p->{timeslot}) . $p->{digest};
}

# --- building (from two in-memory conflicting stakes) -----------------------

# Does $redeem_script hash (either way) to $scripthash? Slashing binds the evidence's
# redeem_script to the real slashed UTXO this way, without needing to know the address
# algorithm (hash160 for pre-quantum, hash256 for post-quantum).
sub redeem_matches_scripthash {
    my $class = shift;
    my ($redeem_script, $scripthash) = @_;
    return 0 unless defined($redeem_script) && defined($scripthash);
    return 1 if hash160($redeem_script) eq $scripthash;
    return 1 if hash256($redeem_script) eq $scripthash;
    return 0;
}

# Deterministic refund outputs for a list of slashed input TXOs: one output per
# scripthash (sorted), value = total minus the fine. Used by both builder and
# validator so the resulting transaction is byte-identical everywhere.
sub canonical_outputs {
    my $class = shift;
    my ($inputs) = @_;
    my %sum;
    foreach my $txo (map { $_->{txo} } @$inputs) {
        $sum{$txo->scripthash} += $txo->value;
    }
    my @out;
    foreach my $sh (sort keys %sum) {
        my $fine = int($sum{$sh} * SLASHING_FINE_NUM / SLASHING_FINE_DEN);
        push @out, QBitcoin::TXO->new_txo({
            value      => $sum{$sh} - $fine,
            scripthash => $sh,
            data       => "",
        });
    }
    return @out;
}

# One proof descriptor for an in-memory stake transaction (block_sign_data set)
sub _proof_of_stake {
    my ($stake) = @_;
    my $bsd = $stake->block_sign_data;
    length($bsd) == PROOF_HEAD_LEN
        or die "Stake " . $stake->hash_str . " has no block_sign_data for slashing\n";
    # NB: no reference to $stake itself here: the proof (via the slashing tx sitting in
    # the mempool) would pin the live equivocated stake and its %TXO-cached txos long
    # after its branch is dropped - the "Attempt to override already loaded txo" trap.
    return {
        prev_hash => substr($bsd, 0, 32),
        timeslot  => unpack("N", substr($bsd, 32, 4)),
        digest    => substr($bsd, 36, 32),
        raw       => $stake->serialize,
    };
}

# Build a slashing transaction from two conflicting in-memory stake transactions
# (both with block_sign_data set). Returns the QBitcoin::Transaction or undef if they
# do not actually conflict (no shared input, same block, or different timeslot).
sub new_tx {
    my $class = shift;
    my ($stake1, $stake2) = @_;
    # The first argument is the live stake (report_equivocation passes the stake of the
    # just-validated block), so its input txos are the real %TXO-cached objects; the
    # second one may be a %SEEN snapshot holding detached txo copies. The slashing tx
    # spends the live objects: report_equivocation marks them spent, and mempool
    # double-spend tracking must see that on the real txo, not on a copy.
    my $p1 = _proof_of_stake($stake1);
    my $p2 = _proof_of_stake($stake2);
    $p1->{timeslot} == $p2->{timeslot}
        or return undef; # different timeslot, not equivocation
    my $cmp = $stake1->block_sign_data cmp $stake2->block_sign_data
        or return undef; # same block
    # Inputs of the slashing tx: the shared (equivocated) UTXOs, taken from the live
    # $stake1 so they are the canonical %TXO-cached txo objects. Input lists of both
    # stakes are sorted by (tx_in, num), so the order is the same on every node no
    # matter which of the two conflicting stakes it received first.
    my %in2 = map { $_->{txo}->key => 1 } @{$stake2->in};
    my @shared = grep { $in2{$_->{txo}->key} } @{$stake1->in}
        or return undef; # no common stake UTXO
    my @in = map { +{ txo => $_->{txo}, siglist => [] } } @shared;
    my @out = $class->canonical_outputs(\@in);
    # Canonical order of the two proofs by block_sign_data (the signed message). Not by
    # stake-tx hash: two stakes that endorse different blocks with the same UTXO/outputs
    # can serialize identically (e.g. staking the same coins on two branches), so the
    # tx hash is not guaranteed to differ - but block_sign_data always does.
    my $evidence = $class->new(proofs => $cmp < 0 ? [ $p1, $p2 ] : [ $p2, $p1 ]);
    my $tx = QBitcoin::Transaction->new(
        in            => \@in,
        out           => \@out,
        tx_type       => TX_TYPE_SLASHING,
        slashing      => $evidence,
        received_time => time(),
    );
    $tx->calculate_fee;
    $tx->calculate_hash;
    return $tx;
}

# --- verification ----------------------------------------------------------

# Reconstruct a stake transaction from a proof and verify its signatures against the
# reassembled block_sign_data. Returns the stake (with ->in populated) or undef.
sub _verify_stake {
    my ($p) = @_;
    my $data = Bitcoin::Serialized->new($p->{raw});
    my $stake = QBitcoin::Transaction->deserialize($data)
        or return undef;
    $data->length == 0
        or return undef; # trailing garbage
    $stake->is_stake
        or return undef;
    my @in;
    foreach my $raw (@{$stake->{in_raw} // []}) {
        # The transient scripthash is internal only (it makes set_redeem_script accept
        # the script); signature verification depends on redeem_script + siglist + the
        # signed message, not on the scripthash. Binding to the real slashed UTXO's
        # scripthash is done later, in validate_slashing.
        my $txo = QBitcoin::TXO->new_txo({
            tx_in      => $raw->{tx_out},
            num        => $raw->{num},
            scripthash => hash256($raw->{redeem_script}),
            data       => "",
        });
        $txo->set_redeem_script($raw->{redeem_script}) == 0
            or return undef;
        push @in, { txo => $txo, siglist => $raw->{siglist} };
    }
    @in
        or return undef;
    $stake->{in} = \@in;
    delete $stake->{in_raw};
    $stake->block_sign_data = _block_sign_data($p);
    $stake->check_input_script == 0
        or return undef;
    return $stake;
}

# Verify the equivocation evidence. Returns a hashref { timeslot => ..., shared =>
# { $utxo_key => { redeem_script => ..., scripthash => ... } } } describing the
# slashable inputs, or undef if the evidence is not a valid equivocation proof.
sub verify {
    my $self = shift;
    my $proofs = $self->proofs;
    @$proofs == 2
        or return undef;
    my ($p1, $p2) = @$proofs;
    $p1->{timeslot} == $p2->{timeslot}
        or return undef;
    # Canonical, strictly-ascending proof ordering by block_sign_data binds the
    # serialization and guarantees the two proofs endorse different blocks.
    _block_sign_data($p1) lt _block_sign_data($p2)
        or return undef;
    my $stake1 = _verify_stake($p1) // return undef;
    my $stake2 = _verify_stake($p2) // return undef;
    my %k1;
    foreach my $in (@{$stake1->in}) {
        $k1{$in->{txo}->key} = $in;
    }
    my %shared;
    foreach my $in (@{$stake2->in}) {
        my $key = $in->{txo}->key;
        my $in1 = $k1{$key}
            or next;
        # same owner: the redeem_script in both stakes must match
        $in1->{txo}->redeem_script eq $in->{txo}->redeem_script
            or return undef;
        $shared{$key} = {
            redeem_script => $in->{txo}->redeem_script,
        };
    }
    %shared
        or return undef; # no shared stake UTXO -> not an equivocation
    return { timeslot => $p1->{timeslot}, shared => \%shared };
}

# --- detection -------------------------------------------------------------

# Record a stake we have seen (block_sign_data already set) and report a previously
# seen, conflicting stake (same UTXO + timeslot, different block) if one exists. Old
# slots beyond the slashing window are pruned. Returns the conflicting stake or undef.
sub observe {
    my $class = shift;
    my ($stake, $timeslot) = @_;
    $stake && $stake->is_stake
        or return undef;
    if ($timeslot > $MAX_SLOT) {
        $MAX_SLOT = $timeslot;
        my $cutoff = $MAX_SLOT - SLASHING_WINDOW * BLOCK_INTERVAL;
        foreach my $s (keys %SEEN) {
            delete $SEEN{$s} if $s < $cutoff;
        }
    }
    my $slot = $SEEN{$timeslot} //= {};
    my $conflict;
    my $snapshot;
    foreach my $in (@{$stake->in}) {
        my $key  = $in->{txo}->key;
        my $prev = $slot->{$key};
        if ($prev) {
            # Same UTXO already staked this slot: equivocation iff it was a different block.
            $conflict //= $prev if $prev->block_sign_data ne $stake->block_sign_data;
        }
        else {
            $slot->{$key} = $snapshot //= _snapshot_stake($stake);
        }
    }
    return $conflict;
}

# A retained copy of a stake for the %SEEN watch list. It is a genuine
# QBitcoin::Transaction (so observe()/new_tx()/_proof_of_stake() keep dealing with a
# single, uniform type), but with its OUTPUT txos rebuilt fresh via create_outputs and
# its INPUT txos replaced by detached copies - none of them registered in the global
# %TXO cache. That is the whole point: retaining the snapshot for SLASHING_WINDOW must
# NOT pin any chain txo, otherwise the unconditional save in Transaction::load_txo
# collides ("Attempt to override already loaded txo") when the corresponding
# transaction is received again after its branch was dropped. For outputs the colliding
# transaction is the stake itself; for inputs it is the PREVIOUS stake (a stake's input
# is the previous stake's output, so pinning the input keeps the weak %TXO entry of
# that output alive - this crashed qecr05 on 2026-07-09 during a reorg).
sub _snapshot_stake {
    my ($stake) = @_;
    return QBitcoin::Transaction->new(
        tx_type         => $stake->tx_type,
        block_sign_data => $stake->block_sign_data,
        hash            => $stake->hash,
        size            => $stake->size,
        in              => [ map { +{ txo => _detached_txo($_->{txo}), siglist => $_->{siglist} } } @{$stake->in} ],
        out             => QBitcoin::Transaction::create_outputs(
            [ map { +{ value => $_->value, scripthash => $_->scripthash, data => $_->data } } @{$stake->out} ],
            $stake->hash,
        ),
    );
}

# A detached copy of a chain txo: same identity (tx_in, num) and payload, but a separate
# object absent from the %TXO cache. Keeps everything the slashing code needs later:
# key() for observe(), redeem_script for the evidence serialization, value/scripthash
# for the canonical refund outputs.
sub _detached_txo {
    my ($txo) = @_;
    my $copy = QBitcoin::TXO->new_txo({
        tx_in      => $txo->tx_in,
        num        => $txo->num,
        value      => $txo->value,
        scripthash => $txo->scripthash,
        data       => $txo->data,
    });
    $copy->{redeem_script} = $txo->redeem_script if defined $txo->redeem_script;
    return $copy;
}

# Mark the stake(s) punished by a (valid) slashing tx as equivocated. Called whenever a
# slashing tx is accepted (built locally or received): from then on any block whose
# stake spends one of these UTXOs in that timeslot is invalid.
sub ban_from_tx {
    my $class = shift;
    my ($tx) = @_;
    my $ev = $tx->slashing
        or return;
    my $timeslot = $ev->proofs->[0]{timeslot};
    foreach my $in (@{$tx->in}) {
        $BANNED{$in->{txo}->key} = { timeslot => $timeslot, txo => $in->{txo} };
    }
    if ($timeslot > $MAX_SLOT) {
        $MAX_SLOT = $timeslot;
    }
    my $cutoff = $MAX_SLOT - SLASHING_WINDOW * BLOCK_INTERVAL;
    foreach my $key (keys %BANNED) {
        delete $BANNED{$key} if $BANNED{$key}->{timeslot} < $cutoff;
    }
}

# Is this stake one we hold equivocation evidence for at the given timeslot? Used by
# block validation to reject a block built on an equivocated stake.
sub is_banned_stake {
    my $class = shift;
    my ($stake, $timeslot) = @_;
    $stake && $stake->is_stake
        or return 0;
    foreach my $in (@{$stake->in}) {
        my $b = $BANNED{$in->{txo}->key}
            or next;
        return 1 if $b->{timeslot} == $timeslot;
    }
    return 0;
}

# The lowest best-branch height that rests on an equivocated stake we can slash (its
# UTXO is currently spent by a stake confirmed in the best branch). generate() drops
# the best branch down to this height and rebuilds, including the slashing tx.
sub banned_height_in_best {
    my $class = shift;
    my $min;
    foreach my $key (keys %BANNED) {
        my $txo = $BANNED{$key}->{txo}
            or next;
        my $out = $txo->tx_out
            or next; # not spent in the best branch (already dropped / never confirmed)
        my $sp = QBitcoin::Transaction->get($out)
            or next;
        my $h = $sp->block_height;
        next unless defined $h; # spender not confirmed in the best branch
        $min = $h if !defined($min) || $h < $min;
    }
    return $min;
}

# Build, validate and inject into the mempool a slashing transaction for an observed
# equivocation, then trigger (re)generation so a staker can include it (on a branch
# where the equivocated UTXO is unspent, e.g. a contesting branch). Returns the tx.
sub report_equivocation {
    my $class = shift;
    my ($stake_new, $stake_old) = @_;
    my $tx = $class->new_tx($stake_new, $stake_old)
        or return undef;
    if (QBitcoin::Transaction->check_by_hash($tx->hash) || QBitcoin::Transaction->has_pending($tx->hash)) {
        return undef; # already known
    }
    $_->{txo}->spent_add($tx) foreach @{$tx->in};
    QBitcoin::TXO->save_all($tx->hash, $tx->out);
    if ($tx->validate != 0) {
        Warningf("Built invalid slashing transaction %s, ignore", $tx->hash_str);
        $_->{txo}->spent_del($tx) foreach @{$tx->in};
        return undef;
    }
    if ($tx->save != 0) {
        $_->{txo}->spent_del($tx) foreach @{$tx->in};
        return undef;
    }
    $tx->process_pending;
    $class->ban_from_tx($tx);
    Infof("Built slashing transaction %s (fine %li) for equivocation", $tx->hash_str, $tx->fee);
    $tx->announce;
    # Let the staker regenerate so the equivocated branch is dropped and the slashing tx
    # enters the chain.
    QBitcoin::Generate::Control->generate_new();
    return $tx;
}

1;
