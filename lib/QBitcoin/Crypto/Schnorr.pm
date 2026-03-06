package QBitcoin::Crypto::Schnorr;
use warnings;
use strict;

use Crypt::PK::ECC::Schnorr;
use Math::GMPz qw(:mpz);

use constant CRYPT_ECC_MODULE => 'Crypt::PK::ECC::Schnorr';

use parent 'QBitcoin::Crypto::ECC';

# BIP-340: normalize private key so that public key always has even y.
# If P = d*G has odd y, replace d with n-d, giving P' = (x, y_even).
sub _normalize_even_y {
    my ($class, $pk) = @_;
    my $compressed = $pk->export_key_raw('public_compressed');
    if (substr($compressed, 0, 1) eq "\x03") {
        my $curve_params = $pk->curve2hash();
        my $n = Math::GMPz->new($curve_params->{order}, 16);
        my $d = Rmpz_init2(256);
        Rmpz_import($d, 32, 1, 1, 0, 0, $pk->export_key_raw('private'));
        my $neg_d = $n - $d;
        my $neg_bin = Rmpz_export(1, 1, 0, 0, $neg_d);
        $neg_bin = ("\x00" x (32 - length($neg_bin))) . $neg_bin if length($neg_bin) < 32;
        $pk = $class->CRYPT_ECC_MODULE->new;
        $pk->import_key_raw($neg_bin, $class->CURVE);
    }
    return $pk;
}

sub import_private_key {
    my $class = shift;
    my ($private_key, $algo) = @_;
    my $pk = $class->CRYPT_ECC_MODULE->new;
    $pk->import_key_raw($private_key, $class->CURVE);
    $pk = $class->_normalize_even_y($pk);
    return $class->new($pk);
}

sub generate_keypair {
    my $class = shift;
    my $pk = $class->CRYPT_ECC_MODULE->new;
    $pk->generate_key($class->CURVE);
    $pk = $class->_normalize_even_y($pk);
    return $class->new($pk);
}

# BIP-340: x-only public key (32 bytes, strip the 02 parity prefix)
sub pubkey_by_privkey {
    my $self = shift;
    return substr($self->pk->export_key_raw('public_compressed'), 1);
}

# BIP-340: use sign_message (deterministic Schnorr, 64-byte signature)
sub signature {
    my $self = shift;
    my ($data) = @_;
    return $self->pk->sign_message($data);
}

# BIP-340: prepend \x02 (even y) and use verify_message
sub verify_signature {
    my $class = shift;
    my ($data, $signature, $pubkey) = @_;

    my $pub = $class->CRYPT_ECC_MODULE->new;
    $pub->import_key_raw("\x02" . $pubkey, $class->CURVE);
    return $pub->verify_message($data, $signature);
}

1;
