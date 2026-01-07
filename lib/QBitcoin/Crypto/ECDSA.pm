package QBitcoin::Crypto::ECDSA;
use warnings;
use strict;

use Crypt::PK::ECC;
use Math::BigInt;

use constant CRYPT_ECC_MODULE => 'Crypt::PK::ECC';

use parent 'QBitcoin::Crypto::ECC';

my %curve_cache;

sub _get_curve_params {
    my ($pk) = @_;

    my $hash = $pk->key2hash()
        or return undef;
    my $curve = $hash->{curve_name}
        or return undef;

    unless ($curve_cache{$curve}) {
        $hash->{curve_order} or return undef;
        my $N = Math::BigInt->from_hex('0x' . $hash->{curve_order});
        my $HALF_N = $N->copy()->bdiv(2); # nb: returns 2 elements in list context
        $curve_cache{$curve} = {
            N      => $N,
            HALF_N => $HALF_N,
        };
    }

    return $curve_cache{$curve};
}

# Parse DER-signature -> (r, s)
sub _parse_der_signature {
    my ($sig) = @_;

    my @bytes = unpack('C*', $sig);

    # DER: 0x30 <total_len> 0x02 <r_len> <r> 0x02 <s_len> <s>
    return unless $bytes[0] == 0x30;
    return unless $bytes[2] == 0x02;

    my $r_len = $bytes[3];
    my $r_bytes = substr($sig, 4, $r_len);

    my $s_offset = 4 + $r_len;
    return unless (unpack('C', substr($sig, $s_offset, 1))) == 0x02;

    my $s_len = unpack('C', substr($sig, $s_offset + 1, 1));
    my $s_bytes = substr($sig, $s_offset + 2, $s_len);

    my $r = Math::BigInt->from_hex('0x' . unpack('H*', $r_bytes));
    my $s = Math::BigInt->from_hex('0x' . unpack('H*', $s_bytes));

    return ($r, $s);
}

# Encoding (r, s) -> DER
sub _encode_der_signature {
    my ($r, $s) = @_;

    my $r_hex = $r->to_hex();
    my $s_hex = $s->to_hex();

    # Add leading zero if higher bit is set
    $r_hex = '00' . $r_hex if hex(substr($r_hex, 0, 2)) >= 0x80;
    $s_hex = '00' . $s_hex if hex(substr($s_hex, 0, 2)) >= 0x80;

    # Padding to even length
    $r_hex = '0' . $r_hex if length($r_hex) % 2;
    $s_hex = '0' . $s_hex if length($s_hex) % 2;

    my $r_bytes = pack('H*', $r_hex);
    my $s_bytes = pack('H*', $s_hex);

    my $r_len = length($r_bytes);
    my $s_len = length($s_bytes);
    my $total_len = 4 + $r_len + $s_len;

    return pack('C*', 0x30, $total_len, 0x02, $r_len)
         . $r_bytes
         . pack('C*', 0x02, $s_len)
         . $s_bytes;
}

# Verify: s <= n/2
sub is_low_s {
    my ($pk, $sig) = @_;

    my $params = _get_curve_params($pk)
        or return undef;
    my ($r, $s) = _parse_der_signature($sig);
    defined($s) or return undef;

    return $s->bcmp($params->{HALF_N}) <= 0;
}

# Normalize signature to low-S form
sub normalize_signature {
    my ($pk, $sig) = @_;

    my $params = _get_curve_params($pk)
        or return undef;
    my ($r, $s) = _parse_der_signature($sig);
    defined($s) or return undef;

    if ($s->bcmp($params->{HALF_N}) > 0) {
        $s = $params->{N}->copy()->bsub($s);
    }

    return _encode_der_signature($r, $s);
}

sub verify_signature {
    my $class = shift;
    my ($data, $signature, $pubkey) = @_;

    my $pub = $class->CRYPT_ECC_MODULE->new;
    $pub->import_key_raw($pubkey, $class->CURVE);
    return 0 unless is_low_s($pub, $signature);
    return $pub->verify_hash($signature, $data);
}

sub signature {
    my $self = shift;
    my ($data) = @_;
    return normalize_signature($self->pk, $self->SUPER::signature($data));
}

1;
