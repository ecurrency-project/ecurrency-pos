package QBitcoin::Script::State;
use warnings;
use strict;

use QBitcoin::Script::Const;

sub new {
    my $class = shift;
    my ($script, $stack, $tx, $input_num, $sigops) = @_;
    # script, cp, stack, if-state, if-stack, alt-stack, exec-depth, tx, input_num, sigops
    return bless [$script, 0, $stack // [], 1, [], [], 0, $tx, $input_num, $sigops], $class;
}

sub script  :lvalue { $_[0]->[0] }
sub cp      :lvalue { $_[0]->[1] }
sub stack     { $_[0]->[2] }
sub ifstate :lvalue { $_[0]->[3] }
sub ifstack   { $_[0]->[4] }
sub altstack  { $_[0]->[5] }
sub execdepth :lvalue { $_[0]->[6] }
sub tx        { $_[0]->[7] }
sub input_num { $_[0]->[8] }
sub sigops  :lvalue  { $_[0]->[9] }

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
