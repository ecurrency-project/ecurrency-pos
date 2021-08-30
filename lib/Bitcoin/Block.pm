package Bitcoin::Block;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::ORM qw(:types find create update delete);
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
    return $config->{regtest} ? undef : $config->{btc_testnet} ?
        ( $self->can('BTC_GENESIS_TESTNET') ? BTC_GENESIS_TESTNET() : undef ) :
        ( $self->can('BTC_GENESIS')         ? BTC_GENESIS()         : undef ) ;
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
    return ($self->bits & 0xff000000) < 0x1e000000 ?
        0xffff / ($self->bits & 0xffffff) * (1 << (8*(29 - ($self->bits >> 24)))) :
        0xffff / ($self->bits & 0xffffff) / (1 << (8*(($self->bits >> 24) - 29)));
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

1;
