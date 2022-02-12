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
);

use Digest::SHA qw(sha1 sha256);
use Crypt::Digest::RIPEMD160 qw(ripemd160);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;

use constant CRYPTO_MODULE => {
    &CRYPT_ALGO_ECDSA   => 'ECDSA::secp256k1',
    &CRYPT_ALGO_SCHNORR => 'Schnorr::secp256k1',
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
        eval "require $module";
        die $@ if $@;
    }
};

sub check_sig {
    my ($data, $signature, $pubkey) = @_;
    my $sig_alg = unpack("C", substr($signature, 0, 1));
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
        Warningf("Unsupported crypto module %s for private key", $algo);
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
die "No suitable algorithms for private key length " . length($private_key) . "\n" if !@algo;
    return @algo;
}

sub signature {
    my ($data, $address, $algo) = @_;
    my $pk = $address->privkey($algo)
        or return undef;
    return pack("C", $algo) . $pk->signature(hash256($data));
}

1;
