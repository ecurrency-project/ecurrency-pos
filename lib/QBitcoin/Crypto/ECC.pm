package QBitcoin::Crypto::ECC;
use warnings;
use strict;

sub verify_signature {
    my $class = shift;
    my ($data, $signature, $pubkey) = @_;

    my $pub = $class->CRYPT_ECC_MODULE->new;
    $pub->import_key_raw($pubkey, $class->CURVE);
    return $pub->verify_hash($signature, $data);
}

sub signature {
    my $self = shift;
    my ($data) = @_;
    return $self->pk->sign_hash($data, 'SHA256');
}

sub new {
    my ($class, $pk) = @_;
    return bless \$pk, $class;
}

sub pk { ${$_[0]} }

sub is_valid_pk {
    my $class = shift;
    my ($private_key) = @_;
    return length($private_key) == 32;
}

sub import_private_key {
    my $class = shift;
    my ($private_key, $algo) = @_;
    my $pk = $class->CRYPT_ECC_MODULE->new;
    $pk->import_key_raw($private_key, $class->CURVE);
    return $class->new($pk);
}

sub pk_serialize {
    my $self = shift;
    return $self->pk->export_key_raw('private');
}

sub pubkey_by_privkey {
    my $self = shift;
    return $self->pk->export_key_raw('public_compressed');
}

sub generate_keypair {
    my $class = shift;
    my $pk = $class->CRYPT_ECC_MODULE->new;
    $pk->generate_key($class->CURVE);
    return $class->new($pk);
}

1;
