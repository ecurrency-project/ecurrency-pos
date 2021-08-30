package QBitcoin::Crypto;
use warnings;
use strict;

use Exporter qw(import);

our @EXPORT_OK = qw(
    check_sig
    hash160
    hash256
    ripemd160
    sha256
    sha1
    checksum32
    signature
    pk_serialize
    pk_import
    pk_alg
    generate_keypair
    scrypt_hash
);

use Digest::SHA qw(sha1 sha256);
use Crypt::Digest::RIPEMD160 qw(ripemd160);
use Crypt::PK::ECC;
use Crypt::Digest::Scrypt qw(scrypt_1024_1_1_256);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;

use constant CRYPTO_MODULE => {
    &CRYPT_ALGO_ECDSA   => 'ECDSA::secp256k1',
    &CRYPT_ALGO_SCHNORR => 'Schnorr::secp256k1',
    &CRYPT_ALGO_FALCON  => 'PQ::Falcon512',
};

sub _crypto_module {
    my ($algo) = @_;
    my $crypto_module = CRYPTO_MODULE->{$algo}
        or return undef;
    return "QBitcoin::Crypto::" . $crypto_module;
}

BEGIN {
    foreach my $algo (keys %{&CRYPTO_MODULE}) {
        my $module = _crypto_module($algo);
        eval "require $module"; ## no critic
        die $@ if $@;
    }
};

sub check_sig {
    my ($data, $signature, $pubkey) = @_;
    my $sig_alg = unpack("C", $signature);
    my $crypto_module = _crypto_module($sig_alg);
    if (!$crypto_module) {
        Debugf("Unsupported signature type %u", $sig_alg);
        return undef;
    }
    return $crypto_module->verify_signature(hash256($data), substr($signature, 1), $pubkey);
}

sub hash160 {
    my ($pubkey) = @_;
    return ripemd160(sha256($pubkey));
}

sub hash256 {
    my ($data) = @_;
    return sha256(sha256($data));
}

sub scrypt_hash {
    my ($data) = @_;
    return scrypt_1024_1_1_256($data);
}

sub checksum32 {
    my ($str) = @_;
    return substr(hash256($str), 0, 4);
}

sub pk_serialize {
    my ($pk) = @_;
    return $pk->pk_serialize;
}

sub pk_import {
    my ($private_key, $algo) = @_;
    my $module = _crypto_module($algo);
    if (!$module) {
        Warningf("Unsupported crypto module %s for private key", CRYPT_ALGO_NAMES->{$algo} // "unknown");
        return undef;
    }
    return $module->import_private_key($private_key);
}

sub pk_alg {
    my ($private_key) = @_;
    my @algo;
    foreach my $algo (sort { $a <=> $b } keys %{&CRYPTO_MODULE}) {
        my $module = _crypto_module($algo);
        push @algo, $algo if $module->is_valid_pk($private_key);
    }
    Errf("No suitable algorithms for private key length %u", length($private_key)) if !@algo;
    return @algo;
}

sub signature {
    my ($data, $address, $algo, $sighash_type) = @_;
    #defined($algo) && defined($sighash_type)
    #    or die "Incorrect params for signature";
    my $pk = $address->privkey($algo)
        or return undef;
    return pack("CC", $sighash_type, $algo) . $pk->signature(hash256($data));
}

sub generate_keypair {
    my ($algo) = @_;
    my $module = _crypto_module($algo);
    if (!$module) {
        Warningf("Unsupported crypto module %s for keypair generation", CRYPT_ALGO_NAMES->{$algo} // "unknown");
        return undef;
    }
    return $module->generate_keypair;
}

1;
