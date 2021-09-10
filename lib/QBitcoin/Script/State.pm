package QBitcoin::Script::State;
use warnings;
use strict;

use QBitcoin::Script::Const;

sub new {
    my $class = shift;
    my ($script, $stack, $tx, $input_num) = @_;
    # script, cp, stack, if-state, if-stack, alt-stack, tx, input_num
    my @stack = $stack ? @$stack : (); # make a copy of stack to prevent siglist modifiactions
    return bless [$script, 0, \@stack, 1, [], [], $tx, $input_num], $class;
}

sub script  :lvalue { $_[0]->[0] }
sub cp      :lvalue { $_[0]->[1] }
sub stack     { $_[0]->[2] }
sub ifstate :lvalue { $_[0]->[3] }
sub ifstack   { $_[0]->[4] }
sub altstack  { $_[0]->[5] }
sub tx        { $_[0]->[6] }
sub input_num { $_->[7] }

sub get_script {
    my ($self, $len) = @_;
    my $res = substr($self->script, $self->cp, $len);
    length($res) == $len or return undef;
    $self->cp += $len;
    return $res;
}

sub set_ifstate {
    my ($self) = @_;
    $self->ifstate = !grep { !$_ } @{$self->ifstack};
}

sub ok {
    my $self = shift;
    my $stack = $self->stack;
    return (@$stack == 1 && $stack->[0] eq TRUE && !@{$self->ifstack});
}

1;
