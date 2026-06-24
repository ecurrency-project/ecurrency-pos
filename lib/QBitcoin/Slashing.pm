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

# Watched stakes for equivocation detection. Holding a reference here keeps a stake
# alive past the moment its block is dropped, which is exactly the retention the user
# asked for: stakes linger for SLASHING_WINDOW so a later conflicting stake can be
# caught. Indexed by timeslot then stake-UTXO key; the stored stake carries the
# block_sign_data it signed.
my %SEEN;       # $timeslot => { $utxo_key => $stake_tx }
my $MAX_SLOT = 0;

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
    my ($txos) = @_;
    my %sum;
    foreach my $txo (@$txos) {
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
    return {
        prev_hash => substr($bsd, 0, 32),
        timeslot  => unpack("N", substr($bsd, 32, 4)),
        digest    => substr($bsd, 36, 32),
        raw       => $stake->serialize,
        stake     => $stake,
    };
}

# Build a slashing transaction from two conflicting in-memory stake transactions
# (both with block_sign_data set). Returns the QBitcoin::Transaction or undef if they
# do not actually conflict (no shared input, same block, or different timeslot).
sub new_tx {
    my $class = shift;
    my ($stake1, $stake2) = @_;
    # Canonical order of the two proofs by block_sign_data (the signed message). Not by
    # stake-tx hash: two stakes that endorse different blocks with the same UTXO/outputs
    # can serialize identically (e.g. staking the same coins on two branches), so the
    # tx hash is not guaranteed to differ - but block_sign_data always does.
    ($stake1, $stake2) = ($stake2, $stake1) if $stake1->block_sign_data gt $stake2->block_sign_data;
    my $p1 = _proof_of_stake($stake1);
    my $p2 = _proof_of_stake($stake2);
    $p1->{timeslot} == $p2->{timeslot}
        or return undef; # different timeslot, not equivocation
    _block_sign_data($p1) ne _block_sign_data($p2)
        or return undef; # same block
    my %in1 = map { $_->{txo}->key => $_->{txo} } @{$stake1->in};
    my @shared = grep { $in1{$_->{txo}->key} } @{$stake2->in};
    @shared
        or return undef; # no common stake UTXO
    my @in  = map { +{ txo => $in1{$_->{txo}->key}, siglist => [] } } @shared;
    my @out = $class->canonical_outputs([ map { $_->{txo} } @in ]);
    my $evidence = $class->new(proofs => [ $p1, $p2 ]);
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
    $stake->block_sign_data(_block_sign_data($p));
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
    my ($stake) = @_;
    $stake && $stake->is_stake
        or return undef;
    my $bsd = $stake->block_sign_data;
    defined($bsd) && length($bsd) == PROOF_HEAD_LEN
        or return undef;
    my $timeslot = unpack("N", substr($bsd, 32, 4));
    if ($timeslot > $MAX_SLOT) {
        $MAX_SLOT = $timeslot;
        my $cutoff = $MAX_SLOT - SLASHING_WINDOW * BLOCK_INTERVAL;
        foreach my $s (keys %SEEN) {
            delete $SEEN{$s} if $s < $cutoff;
        }
    }
    my $slot = $SEEN{$timeslot} //= {};
    my $conflict;
    foreach my $in (@{$stake->in}) {
        my $key  = $in->{txo}->key;
        my $prev = $slot->{$key};
        if ($prev) {
            # Same UTXO already staked this slot: equivocation iff it was a different block.
            $conflict //= $prev if $prev->block_sign_data ne $bsd;
        }
        else {
            $slot->{$key} = $stake;
        }
    }
    return $conflict;
}

# If the best tip's stake is the one a mempool slashing tx punishes (i.e. some slashed
# UTXO is spent by a transaction confirmed at the tip's height), return that slashing
# tx. generate() uses this to decide whether to unconfirm the tip and rebuild including
# the slashing tx (the slashed UTXO becomes free once the tip is unconfirmed).
sub tip_slashing {
    my $class = shift;
    my ($tip) = @_;
    $tip
        or return undef;
    my $height = $tip->height;
    foreach my $tx (QBitcoin::Transaction->mempool_list()) {
        next unless $tx->is_slashing;
        foreach my $in (@{$tx->in}) {
            my $out = $in->{txo}->tx_out
                or next;
            my $sp = QBitcoin::Transaction->get($out);
            return $tx if $sp && defined($sp->block_height) && $sp->block_height == $height;
        }
    }
    return undef;
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
    Infof("Built slashing transaction %s (fine %li) for equivocation", $tx->hash_str, $tx->fee);
    $tx->announce;
    # Let the staker regenerate / contest so the slashing tx can enter the chain.
    QBitcoin::Generate::Control->generate_new();
    return $tx;
}

1;
