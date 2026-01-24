package QBitcoin::Crypto::Schnorr::secp256k1;
use warnings;
use strict;

use parent 'QBitcoin::Crypto::Schnorr';

use constant CURVE => 'secp256k1';

sub is_valid_pubkey {
    my ($class, $pubkey) = @_;
    return length($pubkey) == 32;
}

1;
