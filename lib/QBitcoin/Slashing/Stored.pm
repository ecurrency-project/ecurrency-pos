package QBitcoin::Slashing::Stored;
use warnings;
use strict;

# Persistence of a TX_TYPE_SLASHING transaction's equivocation evidence, so a stored
# slashing transaction can be rebuilt (and its hash re-verified) from the database.
# The evidence is an opaque payload (two stake proofs); it is consensus data already
# committed to by the transaction hash, so a single blob column is enough.

use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::ORM qw(:types fetch find create);

use constant TABLE => 'slashing';

use constant FIELDS => {
    tx_id    => NUMERIC, # transaction.id of the slashing transaction
    evidence => BINARY,  # serialized equivocation evidence (two stake proofs)
};

use constant PRIMARY_KEY => qw(tx_id);

mk_accessors(keys %{&FIELDS});

1;
