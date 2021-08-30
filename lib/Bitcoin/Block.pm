package Bitcoin::Block;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::ORM qw(:types fetch find create update delete);
use QBitcoin::Crypto qw(hash256 scrypt_hash);
use Role::Tiny::With;
with 'QBitcoin::Block::MerkleTree';

use constant TABLE => 'btc_block';

use constant FIELDS => {
    version     => NUMERIC,
    height      => NUMERIC,
    time        => NUMERIC,
    bits        => NUMERIC,
    nonce       => NUMERIC,
    chainwork   => NUMERIC,
    scanned     => NUMERIC,
    hash        => BINARY,
    prev_hash   => BINARY,
    merkle_root => BINARY,
};
use constant PRIMARY_KEY => 'hash';

mk_accessors(keys %{&FIELDS});
mk_accessors(qw(transactions));

sub genesis_hash() {
    my $self = shift;
    return $config->{regtest} ? undef : BTC_GENESIS;
}

sub genesis_hash_hex {
    my $self = shift;
    return $self->genesis_hash ? unpack("H*", scalar reverse $self->genesis_hash) : undef;
}

sub calculate_hash {
    my $self = shift;
    my $data = pack("V", $self->version) . $self->prev_hash . $self->merkle_root .
        pack("VVV", $self->time, $self->bits, $self->nonce);
    return hash256($data);
}

sub deserialize {
    my $class = shift;
    my ($data) = @_;

    if ($data->length < 80) {
        Warningf("Incorrect serialized block header, length %u < 80", $data->length);
        return undef;
    }
    my ($version, $prev_block, $merkle_root, $timestamp, $bits, $nonce) = unpack("Va32a32VVV", $data->get(80));
    my $block = $class->new(
        version     => $version,
        prev_hash   => $prev_block,
        merkle_root => $merkle_root,
        time        => $timestamp,
        bits        => $bits,
        nonce       => $nonce,
    );
    $block->hash = $block->calculate_hash;
    return $block;
}

sub serialize {
    my $self = shift;
    return pack("Va32a32VVV",
        $self->version, $self->prev_hash, $self->merkle_root, $self->time, $self->bits, $self->nonce);
}

sub difficulty {
    my $self = shift;
    # https://bitcoin.stackexchange.com/questions/5838/how-is-difficulty-calculated
    # https://www.oreilly.com/library/view/mastering-bitcoin/9781491902639/ch08.html#difficulty_bits
    # difficulty = difficulty_1_target / current_target = (0xffff/coef) * 256^(29-expo)
    # Use floating-point 2**N rather than integer "1 << N": for high-difficulty blocks
    # (small exponent) the shift count reaches >= 64 and "1 << N" silently overflows to 0
    # on a 64-bit perl, which would make a real bitcoin block contribute zero chainwork;
    # for a large exponent the divisor "1 << N" becomes 0 and crashes with division by zero.
    my $coef = $self->bits & 0xffffff;
    my $expo = $self->bits >> 24;
    return $coef ? 0xffff / $coef * 2**(8*(29 - $expo)) : 0;
}

sub pow_hash {
    my $self = shift;
    my $data = pack("V", $self->version) . $self->prev_hash . $self->merkle_root .
        pack("VVV", $self->time, $self->bits, $self->nonce);
    return scrypt_hash($data);
}

sub validate {
    my $self = shift;
    # compare hash with bits
    my $bits_coef = $self->bits & 0xffffff;
    my $bits_expo = $self->bits >> 24;
    # Reject nonsensical "bits" before using them to index into the hash below.
    # A valid bitcoin target keeps the coefficient within 32 bytes and is non-zero;
    # the checks below read a 4-byte window at offset (32-expo-4), which only stays
    # inside the 32-byte hash for 4 <= expo <= 31. Out-of-range values are garbage
    # (and would otherwise read past the string / compare against an empty pattern).
    if ($bits_coef == 0 || $bits_expo < 4 || $bits_expo > 31) {
        Warningf("PoW bits out of range: block hash %s, bits %u, coef %u, expo %u", unpack("H*", reverse $self->hash), $self->bits, $bits_expo, $bits_coef);
        return 0;
    }
    my $zero_bytes = 32-$bits_expo;
    # hash must have first 8*(32-$bits_expo) zero bits
    my $pow_hash = $self->pow_hash;
    if (substr($pow_hash, -$zero_bytes) ne "\x00" x $zero_bytes) {
        Warningf("PoW bytes: block hash %s, bits %u, coef %u, expo %u", unpack("H*", reverse $pow_hash), $self->bits, $bits_expo, $bits_coef);
        return 0;
    }
    if (unpack("V", substr($pow_hash, -$zero_bytes-4, 4)) >= $bits_coef * 256) {
        Warningf("PoW value fail: block hash %s, bits %u, coef %u, expo %u", unpack("H*", reverse $pow_hash), $self->bits, $bits_expo, $bits_coef);
        return 0;
    }
    return 1;
}

sub hash_hex {
    my $self = shift;
    return unpack("H*", scalar reverse $self->hash);
}

sub prev_hash_hex {
    my $self = shift;
    return unpack("H*", scalar reverse $self->prev_hash);
}

sub tx_hashes {
    my $self = shift;
    return [ map { $_->hash } @{$self->transactions} ];
}

my $upgrade_stopped_block;

sub upgrade_stopped {
    my ($timeslot) = @_;
    return 1 if UPGRADE_FINISHED;
    $upgrade_stopped_block //= __PACKAGE__->find(height => UPGRADE_MAX_BLOCKS + COINBASE_CONFIRM_BLOCKS) // 0;
    return 0 unless $upgrade_stopped_block;
    return $timeslot >= $upgrade_stopped_block->time + COINBASE_CONFIRM_TIME;
}

sub update_btc_stopped {
    my $self = shift;
    if ($self->height == UPGRADE_MAX_BLOCKS + COINBASE_CONFIRM_BLOCKS) {
        $upgrade_stopped_block = $self;
    }
}

1;
