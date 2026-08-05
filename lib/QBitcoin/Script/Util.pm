package QBitcoin::Script::Util;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(unpack_int pack_int);

# Script integers are sign-magnitude: the first packed field holds the most
# significant bits of the magnitude and the sign in its own most significant bit,
# each following field appends lower bits. Valid lengths are 1-8 bytes, so the
# magnitude is limited to 2**63-1 and always fits a native Perl integer.
# Amounts in satoshi (up to MAX_VALUE) need 7 bytes.

sub unpack_int($) {
    my ($data) = @_;
    defined($data) or return undef;
    my $l = length($data);
    if ($l == 1) {
        my $n = unpack("C", $data);
        return $n & 0x80 ? -($n ^ 0x80) : $n;
    }
    elsif ($l == 2) {
        my $n = unpack("v", $data);
        return $n & 0x8000 ? -($n ^ 0x8000) : $n;
    }
    elsif ($l == 4) {
        my $n = unpack("V", $data);
        return $n & 0x80000000 ? -($n ^ 0x80000000) : $n;
    }
    elsif ($l == 3) {
        my ($first, $last) = unpack("vC", $data);
        return $first & 0x8000 ? -(($first ^ 0x8000) << 8 | $last) : $first << 8 | $last;
    }
    elsif ($l == 5) {
        my ($first, $last) = unpack("VC", $data);
        return $first & 0x80000000 ? -(($first ^ 0x80000000) << 8 | $last) : $first << 8 | $last;
    }
    elsif ($l == 6) {
        my ($first, $last) = unpack("Vv", $data);
        return $first & 0x80000000 ? -(($first ^ 0x80000000) << 16 | $last) : $first << 16 | $last;
    }
    elsif ($l == 7) {
        my ($first, $mid, $last) = unpack("VvC", $data);
        my $low = $mid << 8 | $last;
        return $first & 0x80000000 ? -(($first ^ 0x80000000) << 24 | $low) : $first << 24 | $low;
    }
    elsif ($l == 8) {
        my ($first, $low) = unpack("VV", $data);
        return $first & 0x80000000 ? -(($first ^ 0x80000000) << 32 | $low) : $first << 32 | $low;
    }
    else {
        return undef;
    }
}

# Returns undef if the value does not fit 8-byte sign-magnitude (|n| >= 2**63),
# including float results of overflowed 64-bit integer arithmetic; the caller
# must treat undef as script failure.
sub pack_int($) {
    my ($n) = @_;
    if ($n >= 0) {
        if ($n < 0x80) {
            return pack("C", $n);
        }
        elsif ($n < 0x8000) {
            return pack("v", $n);
        }
        elsif ($n < 0x800000) {
            return pack("vC", $n >> 8, $n & 0xff);
        }
        elsif ($n < 0x80000000) {
            return pack("V", $n);
        }
        elsif ($n < 0x80000000 << 8) {
            return pack("VC", $n >> 8, $n & 0xff);
        }
        elsif ($n < 0x80000000 << 16) {
            return pack("Vv", $n >> 16, $n & 0xffff);
        }
        elsif ($n < 0x80000000 << 24) {
            return pack("VvC", $n >> 24, ($n >> 8) & 0xffff, $n & 0xff);
        }
        elsif ($n < 0x80000000 << 32) {
            return pack("VV", $n >> 32, $n & 0xffffffff);
        }
        else {
            return undef;
        }
    }
    else {
        if ($n > -0x80) {
            return pack("C", 0x80 | -$n);
        }
        elsif ($n > -0x8000) {
            return pack("v", 0x8000 | -$n);
        }
        elsif ($n > -0x800000) {
            return pack("vC", 0x8000 | (-$n >> 8), -$n & 0xff);
        }
        elsif ($n > -0x80000000) {
            return pack("V", 0x80000000 | -$n);
        }
        elsif ($n > -(0x80000000 << 8)) {
            return pack("VC", 0x80000000 | (-$n >> 8), -$n & 0xff);
        }
        elsif ($n > -(0x80000000 << 16)) {
            return pack("Vv", 0x80000000 | (-$n >> 16), -$n & 0xffff);
        }
        elsif ($n > -(0x80000000 << 24)) {
            return pack("VvC", 0x80000000 | (-$n >> 24), (-$n >> 8) & 0xffff, -$n & 0xff);
        }
        elsif ($n > -(0x80000000 << 32)) {
            return pack("VV", 0x80000000 | (-$n >> 32), -$n & 0xffffffff);
        }
        else {
            return undef;
        }
    }
}

1;
