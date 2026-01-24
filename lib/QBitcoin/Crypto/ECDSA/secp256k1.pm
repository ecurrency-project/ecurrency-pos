package QBitcoin::Crypto::ECDSA::secp256k1;
use warnings;
use strict;

use parent 'QBitcoin::Crypto::ECDSA';

use constant CURVE => 'secp256k1';

sub is_valid_pubkey {
    my ($class, $pubkey) = @_;
    my $firstbyte = substr($pubkey, 0, 1);
    if ($firstbyte eq "\x04") {
        return length($pubkey) == 65;
    }
    elsif ($firstbyte eq "\x02" || $firstbyte eq "\x03") {
        return length($pubkey) == 33;
    }
    else {
        return 0;
    }
}

1;
