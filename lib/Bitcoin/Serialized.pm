package Bitcoin::Serialized;
use warnings;
use strict;

use Exporter qw(import);
our @EXPORT = qw(varint varstr);

# Object with [ $data, $index ] to avoid rewrite long data during deserialize

sub new {
    my ($class, $data) = @_;
    bless [ $data, 0 ], $class;
}

sub data {
    $_[0]->[0];
}

sub index :lvalue {
    $_[0]->[1];
}

sub length :method {
    length($_[0]->[0]) - $_[0]->[1];
}

sub get {
    my ($self, $len) = @_;
    my $res = substr($self->[0], $self->[1], $len);
    length($res) == $len or return undef;
    $self->[1] += $len;
    return $res;
}

sub varint {
    my ($num) = @_;
    return $num < 0xFD ? pack("C", $num) :
        $num <= 0xFFFF ? pack("Cv", 0xFD, $num) :
        $num <= 0xFFFFFFFF ? pack("CV", 0xFE, $num) :
        pack("CQ<", 0xFF, $num);
}

sub get_varint {
    my $self = shift;
    my $first = unpack("C", $self->get(1))
        // return undef;
    # We do not check if $data has enough data, but if not we will fail on next step, get items
    return $first < 0xFD ? $first :
        $first == 0xFD ? unpack("v", $self->get(2) // return undef) :
        $first == 0xFE ? unpack("V", $self->get(4) // return undef) :
        unpack("Q<", $self->get(8) // return undef);
}

sub varstr {
    my ($str) = @_;
    return varint(length($str)) . $str;
}

sub get_string {
    my $self = shift;
    my $n = $self->get_varint() // return undef;
    return $n ? $self->get($n) : "";
}

1;
