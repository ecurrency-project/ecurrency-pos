package QBitcoin::Address;
use warnings;
use strict;

# Private key format compatible with bitcoin; public key and address are not

use Math::GMPz;
use Encode::Base58::GMP qw(encode_base58 decode_base58);
use QBitcoin::Config;
use QBitcoin::Const;
use QBitcoin::BlockchainParams;
use QBitcoin::Crypto qw(hash160 hash256 checksum32);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);

use constant CHECKSUM_LEN => 4;

use Exporter qw(import);
our @EXPORT_OK = qw(
    wallet_import_format
    wif_to_pk
    address_by_pubkey
    addresses_by_pubkey
    address_by_hash
    validate_address
    script_by_pubkey
    script_by_pubkeyhash
    scripthash_by_address
);

sub wallet_import_format($) {
    my ($private_key) = @_;

    my $data = ADDRESS_VER . $private_key;
    return encode_base58('0x' . unpack('H*', $data . checksum32($data)), 'bitcoin');
}

sub wif_to_pk($) {
    my ($private_wif) = shift;
    my $gmpz_obj = decode_base58($private_wif, 'bitcoin');
    my $bin = Math::GMPz::Rmpz_export(1, 1, 0, 0, $gmpz_obj);
    my $crc = substr($bin, -CHECKSUM_LEN, CHECKSUM_LEN, "");
    checksum32($bin) eq $crc
        or die "Incorrect checksum";
    substr($bin, 0, 1, "") eq ADDRESS_VER
        or die "Incorrect address version";
    return $bin;
}

# qbitcoin part, incompatible with bitcoin

sub script_by_pubkey {
    my ($public_key) = @_;
    return op_pushdata($public_key) . OP_CHECKSIG;
}

sub script_by_pubkeyhash {
    my ($publickeyhash) = @_;
    return OP_DUP . OP_HASH160 . op_pushdata($publickeyhash) . OP_EQUALVERIFY . OP_CHECKSIG;
}

sub address_by_hash($) {
    my ($scripthash) = shift;
    my $data = ADDR_MAGIC . $scripthash;
    return encode_base58("0x" . unpack("H*", $data . checksum32($data)), "bitcoin");
}

sub address_by_pubkey($$) {
    my ($public_key, $alg) = @_;

    my $script = script_by_pubkey($public_key);
    my $hash = $alg & CRYPT_ALGO_POSTQUANTUM ? hash256($script) : hash160($script);
    return address_by_hash($hash);
}

sub addresses_by_pubkey($$) {
    my ($public_key, $alg) = @_;

    my $script = script_by_pubkey($public_key);
    my $scripthash160 = hash160($script);
    my $scripthash256 = hash256($script);
    my @hash = $alg & CRYPT_ALGO_POSTQUANTUM ? ($scripthash256, $scripthash160) : ($scripthash160, $scripthash256);
    # This address can be generated from the legacy bitcoin address 1xxx which contains hash160($public_key)
    push @hash, hash160(script_by_pubkeyhash(hash160($public_key)));
    return map { address_by_hash($_) } @hash;
}

sub validate_address($) {
    my ($address) = @_;

    return 0 unless $address;
    $address =~ ADDRESS_RE
        or return 0;
    my $gmpz_obj = eval { decode_base58($address, 'bitcoin') };
    return 0 if $@;

    my $bin = Math::GMPz::Rmpz_export(1, 1, 0, 0, $gmpz_obj);
    my $crc = substr($bin, -CHECKSUM_LEN, CHECKSUM_LEN, "");
    checksum32($bin) eq $crc
        or return 0;
    return substr($bin, 0, length(ADDR_MAGIC)) eq ADDR_MAGIC;
}

sub scripthash_by_address($) {
    my ($address) = shift;

    # TODO: parse POW-addresses, fetch pubkeyhash and then create scripthash by the pubkeyhash
    my $gmpz_obj = decode_base58($address, 'bitcoin');
    my $bin = Math::GMPz::Rmpz_export(1, 1, 0, 0, $gmpz_obj);
    my $crc = substr($bin, -CHECKSUM_LEN, CHECKSUM_LEN, "");
    checksum32($bin) eq $crc
        or die "Incorrect address checksum\n";
    substr($bin, 0, length(ADDR_MAGIC), "") eq ADDR_MAGIC
        or die "Incorrect address version\n";
    return $bin;
}

1;
