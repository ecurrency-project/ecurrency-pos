package QBitcoin::Slashing::Stored;
use warnings;
use strict;

# Persistence of a TX_TYPE_SLASHING transaction's equivocation evidence, so a stored
# slashing transaction can be rebuilt (and its hash re-verified) from the database. The
# evidence is two stake proofs; both share one timeslot, the rest is stored per proof
# (an inspectable expanded form rather than one opaque blob).

use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::ORM qw(:types fetch find create);

use constant TABLE => 'slashing';

use constant FIELDS => {
    tx_id      => NUMERIC, # transaction.id of the slashing transaction
    timeslot   => NUMERIC, # shared timeslot of both equivocating blocks
    prev_hash1 => BINARY,  # proof 1: previous-block hash, tx-set digest, stake-tx bytes
    digest1    => BINARY,
    raw1       => BINARY,
    prev_hash2 => BINARY,  # proof 2
    digest2    => BINARY,
    raw2       => BINARY,
};

use constant PRIMARY_KEY => qw(tx_id);

mk_accessors(keys %{&FIELDS});

1;
