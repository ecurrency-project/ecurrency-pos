package QBitcoin::Script::Util;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(unpack_int pack_int);

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
    else {
        return undef;
    }
}

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
        else {
            die "Error in script eval (too large int for push to stack)\n";
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
        else {
            die "Error in script eval (too large int)\n";
        }
    }
}

1;
