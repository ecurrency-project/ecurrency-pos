package Bitcoin::Address;
use warnings;
use strict;

# Bitcoin address encoding, decoding and validation.
# Supports all standard address types:
#   - P2PKH  (Base58Check, version 0x00 mainnet / 0x6F testnet)
#   - P2SH   (Base58Check, version 0x05 mainnet / 0xC4 testnet)
#   - P2WPKH (Bech32, witness v0 + 20-byte program)  - BIP-173
#   - P2WSH  (Bech32, witness v0 + 32-byte program)  - BIP-173
#   - P2TR   (Bech32m, witness v1 + 32-byte x-only pubkey) - BIP-341/350
#   - Future segwit (Bech32m, witness v2..v16 + program)
#
# Address strings are the canonical representation used throughout:
# createrawtransaction stores the address string (ASCII) directly in the
# TXO data field; decoderawtransaction reads it back as-is.

use Math::GMPz;
use Encode::Base58::GMP qw(encode_base58 decode_base58);
use QBitcoin::Crypto qw(checksum32);

use Exporter qw(import);
our @EXPORT_OK = qw(
    is_btc_address
    decode_btc_address
    encode_btc_address
    encode_p2wpkh
    encode_p2wsh
    encode_p2tr
    btc_address_to_scriptpubkey
);

use constant CHECKSUM_LEN => 4;

# ---- Base58Check (P2PKH, P2SH) ------------------------------------------

sub _base58check_decode {
    my ($address) = @_;
    my $gmpz = eval { decode_base58($address, 'bitcoin') };
    return () if $@;
    my $bin = Math::GMPz::Rmpz_export(1, 1, 0, 0, $gmpz);
    # Re-add leading 0x00 bytes that BigInteger drops.
    # Each leading '1' in the Base58 string represents one 0x00 byte (BIP-350 / Bitcoin convention).
    my ($ones) = ($address =~ /^(1*)/);
    $bin = "\x00" x length($ones) . $bin;
    my $crc = substr($bin, -CHECKSUM_LEN, CHECKSUM_LEN, "");
    return () unless checksum32($bin) eq $crc;
    return () unless length($bin) == 21; # 1 byte version + 20 bytes hash160
    return (substr($bin, 0, 1), substr($bin, 1));
}

sub _base58check_encode {
    my ($ver_byte, $hash160) = @_;
    my $payload = $ver_byte . $hash160;
    my $full    = $payload . checksum32($payload);
    my ($leading) = ($full =~ /^(\x00*)/);
    my $n_zeros   = length($leading);
    my $encoded   = encode_base58("0x" . unpack("H*", $full), "bitcoin");
    return "1" x $n_zeros . $encoded;
}

# ---- Bech32 / Bech32m (SegWit, Taproot) - BIP-173 / BIP-350 ------------

my $CHARSET     = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
my %CHARSET_MAP = map { substr($CHARSET, $_, 1) => $_ } 0 .. 31;

use constant BECH32_CONST  => 1;            # BIP-173 (witness version 0)
use constant BECH32M_CONST => 0x2bc830a3;   # BIP-350 (witness version 1+)

# Generator for the GF(2^32) BCH code used by bech32/bech32m.
my @_GEN = (0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3);

sub _polymod {
    my $chk = 1;
    for my $v (@_) {
        my $b = $chk >> 25;
        $chk = (($chk & 0x1ffffff) << 5) ^ $v;
        for my $i (0 .. 4) {
            $chk ^= (($b >> $i) & 1) ? $_GEN[$i] : 0;
        }
    }
    return $chk;
}

sub _hrp_expand {
    my ($hrp) = @_;
    my @c = map { ord($_) } split //, $hrp;
    return ((map { $_ >> 5 } @c), 0, (map { $_ & 31 } @c));
}

sub _create_checksum {
    my ($hrp, $data, $const) = @_;
    my $poly = _polymod(_hrp_expand($hrp), @$data, 0, 0, 0, 0, 0, 0) ^ $const;
    return map { ($poly >> (5 * (5 - $_))) & 31 } 0 .. 5;
}

# Convert between bit-group sizes (e.g. 8-bit bytes ↔ 5-bit bech32 groups).
# $pad: 1 = pad output, 0 = fail if padding needed (for decode).
sub _convertbits {
    my ($data, $frombits, $tobits, $pad) = @_;
    my ($acc, $bits) = (0, 0);
    my @ret;
    my $maxv = (1 << $tobits) - 1;
    for my $v (@$data) {
        $acc = (($acc << $frombits) | $v) & 0xffffffff;
        $bits += $frombits;
        while ($bits >= $tobits) {
            $bits -= $tobits;
            push @ret, ($acc >> $bits) & $maxv;
        }
    }
    if ($pad) {
        push @ret, ($acc << ($tobits - $bits)) & $maxv if $bits;
    }
    elsif ($bits >= $frombits || (($acc << ($tobits - $bits)) & $maxv)) {
        return undef;
    }
    return \@ret;
}

# Decode a bech32/bech32m segwit address.
# Returns ($witness_version, $witness_program_bytes) or ().
# Accepts mixed case (whole string must be uniform case per BIP-173).
sub _decode_bech32 {
    my ($addr) = @_;
    my $lower = lc($addr);
    return () if $lower ne $addr && uc($addr) ne $addr; # mixed case
    $addr = $lower;

    my $sep = rindex($addr, '1');
    return () if $sep < 1 || length($addr) - $sep - 1 < 6; # min 6 data chars

    my $hrp      = substr($addr, 0, $sep);
    my $data_str = substr($addr, $sep + 1);

    my @data;
    for my $c (split //, $data_str) {
        return () unless exists $CHARSET_MAP{$c};
        push @data, $CHARSET_MAP{$c};
    }

    my $wit_ver = $data[0];
    return () if $wit_ver > 16;

    my $const = $wit_ver == 0 ? BECH32_CONST : BECH32M_CONST;
    return () unless _polymod(_hrp_expand($hrp), @data) == $const;

    # Decode the witness program (skip version and 6-char checksum).
    my $decoded = _convertbits([@data[1 .. $#data - 6]], 5, 8, 0);
    return () unless defined $decoded;

    my $prog_len = scalar @$decoded;
    return () if $prog_len < 2 || $prog_len > 40;
    # Witness version 0: 20 bytes (P2WPKH) or 32 bytes (P2WSH).
    return () if $wit_ver == 0 && $prog_len != 20 && $prog_len != 32;
    # Witness version 1 (Taproot): exactly 32 bytes.
    return () if $wit_ver == 1 && $prog_len != 32;

    return ($hrp, $wit_ver, pack("C*", @$decoded));
}

# Encode a segwit address (bech32 for v0, bech32m for v1+).
sub _encode_bech32 {
    my ($hrp, $wit_ver, $program) = @_;
    my $data = _convertbits([unpack("C*", $program)], 8, 5, 1);
    return undef unless defined $data;
    unshift @$data, $wit_ver;
    my $const    = $wit_ver == 0 ? BECH32_CONST : BECH32M_CONST;
    my @checksum = _create_checksum($hrp, $data, $const);
    return $hrp . '1' . join('', map { substr($CHARSET, $_, 1) } (@$data, @checksum));
}

# ---- Public API ----------------------------------------------------------

# is_btc_address($str) → 1 if $str is any valid Bitcoin address, 0 otherwise.
sub is_btc_address {
    my ($addr) = @_;
    return 0 unless defined $addr && length($addr) >= 14;
    return 1 if _base58check_decode($addr);
    return 1 if _decode_bech32($addr);
    return 0;
}

# decode_btc_address($addr) → hashref with type/version/hash info, or undef.
#
# Returned hashref always has:
#   type    => 'p2pkh' | 'p2sh' | 'p2wpkh' | 'p2wsh' | 'p2tr' | 'segwit'
#   hash    => raw binary hash (hash160 for P2PKH/P2SH/P2WPKH; sha256 for P2WSH/P2TR)
#
# Additionally for Base58Check types:
#   version => version byte as integer (0x00 for P2PKH, 0x05 for P2SH, etc.)
#
# Additionally for Bech32/Bech32m types:
#   witness_version => integer (0 for SegWit, 1 for Taproot)
#   hrp             => human-readable part ("bc", "tb", etc.)
sub decode_btc_address {
    my ($addr) = @_;
    return undef unless defined $addr;

    # Try Base58Check (P2PKH, P2SH, and exotic mainnet/testnet versions).
    if (my ($ver_bin, $hash) = _base58check_decode($addr)) {
        my $ver  = unpack("C", $ver_bin);
        my $type = $ver == 0x00 || $ver == 0x6F ? 'p2pkh'
                 : $ver == 0x05 || $ver == 0xC4 ? 'p2sh'
                 :                                 'base58check';
        return { type => $type, version => $ver, hash => $hash };
    }

    # Try Bech32 / Bech32m (SegWit, Taproot).
    if (my ($hrp, $wit_ver, $prog) = _decode_bech32($addr)) {
        my $plen = length($prog);
        my $type = $wit_ver == 0 && $plen == 20 ? 'p2wpkh'
                 : $wit_ver == 0 && $plen == 32 ? 'p2wsh'
                 : $wit_ver == 1 && $plen == 32 ? 'p2tr'
                 :                                 'segwit';
        return { type => $type, witness_version => $wit_ver, hash => $prog, hrp => $hrp };
    }

    return undef;
}

# encode_btc_address($ver_byte, $hash160) → Base58Check address string.
# $ver_byte is a single raw binary byte (e.g. "\x00" for P2PKH mainnet).
# Kept for compatibility with code that builds addresses from (version, hash160).
sub encode_btc_address {
    my ($ver_byte, $hash160) = @_;
    return _base58check_encode($ver_byte, $hash160);
}

# encode_p2wpkh($hash160, $hrp) → Bech32 P2WPKH address.
# $hrp defaults to "bc" (mainnet).
sub encode_p2wpkh {
    my ($hash160, $hrp) = @_;
    $hrp //= "bc";
    return _encode_bech32($hrp, 0, $hash160);
}

# encode_p2wsh($sha256, $hrp) → Bech32 P2WSH address.
sub encode_p2wsh {
    my ($sha256, $hrp) = @_;
    $hrp //= "bc";
    return _encode_bech32($hrp, 0, $sha256);
}

# encode_p2tr($xonly_pubkey, $hrp) → Bech32m P2TR address.
sub encode_p2tr {
    my ($xonly, $hrp) = @_;
    $hrp //= "bc";
    return _encode_bech32($hrp, 1, $xonly);
}

# btc_address_to_scriptpubkey($addr) → binary Bitcoin scriptPubKey, or undef.
# Used when building raw Bitcoin transactions without RPC assistance.
sub btc_address_to_scriptpubkey {
    my ($addr) = @_;
    my $info = decode_btc_address($addr);
    return undef unless $info;

    if ($info->{type} eq 'p2pkh') {
        # OP_DUP OP_HASH160 PUSH20 <hash160> OP_EQUALVERIFY OP_CHECKSIG
        return "\x76\xa9\x14" . $info->{hash} . "\x88\xac";
    }
    elsif ($info->{type} eq 'p2sh') {
        # OP_HASH160 PUSH20 <hash160> OP_EQUAL
        return "\xa9\x14" . $info->{hash} . "\x87";
    }
    elsif ($info->{type} eq 'p2wpkh') {
        # OP_0 PUSH20 <hash160>
        return "\x00\x14" . $info->{hash};
    }
    elsif ($info->{type} eq 'p2wsh') {
        # OP_0 PUSH32 <sha256>
        return "\x00\x20" . $info->{hash};
    }
    elsif ($info->{type} eq 'p2tr') {
        # OP_1 PUSH32 <x-only pubkey>  (OP_1 = 0x51)
        return "\x51\x20" . $info->{hash};
    }
    else {
        # Generic future segwit: OP_{ver} PUSH<len> <program>
        my $ver = $info->{witness_version};
        my $op  = $ver == 0 ? 0x00 : 0x50 + $ver; # OP_0..OP_16
        return pack("CC", $op, length($info->{hash})) . $info->{hash};
    }
}

1;
