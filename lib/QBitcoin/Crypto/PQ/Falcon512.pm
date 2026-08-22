package QBitcoin::Crypto::PQ::Falcon512;
use warnings;
use strict;

use Crypt::PQClean::Sign qw(falcon512_keypair falcon512_sign falcon512_verify);
use Crypt::PRNG qw(random_bytes);

use constant PRIVATE_KEY_LENGTH => 1281;
use constant PUBLIC_KEY_LENGTH  => 897;

sub generate_keypair {
    my $class = shift;
    my ($pk, $sk) = falcon512_keypair();
    return $class->new($sk, $pk);
}

sub verify_signature {
    my $class = shift;
    my ($data, $signature, $pubkey) = @_;
    return falcon512_verify($signature, $data, $pubkey);
}

sub signature {
    my $self = shift;
    my ($data) = @_;
    return falcon512_sign($data, $self->[0]);
}

sub new {
    my $class = shift;
    my ($private_key, $public_key) = @_;
    return bless [ $private_key, $public_key ], $class;
}

sub pk_serialize {
    my $self = shift;
    return $self->[0] . $self->[1];
}

sub pubkey_by_privkey {
    my $self = shift;
    return $self->[1];
}

sub is_valid_pk {
    my $class = shift;
    my ($private_key) = @_;
    return length($private_key) == PRIVATE_KEY_LENGTH + PUBLIC_KEY_LENGTH;
}

sub is_valid_pubkey {
    my $class = shift;
    my ($public_key) = @_;
    return length($public_key) == PUBLIC_KEY_LENGTH;
}

sub import_private_key {
    my $class = shift;
    my ($pk, $algo) = @_;
    $class->is_valid_pk($pk)
        or return undef;
    my $self = $class->new(substr($pk, 0, PRIVATE_KEY_LENGTH), substr($pk, PRIVATE_KEY_LENGTH));
    # The serialized key is a plain concatenation of the private and public keys,
    # and the public key cannot be derived from the private one to compare them;
    # prove the halves match by a sign/verify roundtrip
    my $message = random_bytes(32);
    my $signature = eval { falcon512_sign($message, $self->[0]) }
        or die "Invalid falcon512 private key\n";
    falcon512_verify($signature, $message, $self->[1])
        or die "Falcon512 private key does not match the public key\n";
    return $self;
}

1;
