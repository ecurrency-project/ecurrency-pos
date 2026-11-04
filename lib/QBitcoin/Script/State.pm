package QBitcoin::Script::State;
use warnings;
use strict;

use QBitcoin::Script::Const;

sub new {
    my $class = shift;
    my ($script, $stack, $tx, $input_num, $sigops) = @_;
    # script, cp, stack, false if-branches, if-stack, alt-stack, exec-depth, tx, input_num, sigops
    return bless [$script, 0, $stack // [], 0, [], [], 0, $tx, $input_num, $sigops], $class;
}

sub script  :lvalue { $_[0]->[0] }
sub cp      :lvalue { $_[0]->[1] }
sub stack     { $_[0]->[2] }
sub iffalse :lvalue { $_[0]->[3] } # number of false entries in ifstack
sub ifstack   { $_[0]->[4] }
sub altstack  { $_[0]->[5] }
sub execdepth :lvalue { $_[0]->[6] }
sub tx        { $_[0]->[7] }
sub input_num { $_[0]->[8] }
sub sigops  :lvalue  { $_[0]->[9] }

# True while no enclosing IF branch is false, O(1) thanks to the iffalse counter
sub ifstate { !$_[0]->[3] }

sub get_script {
    my ($self, $len) = @_;
    my $res = substr($self->script, $self->cp, $len);
    length($res) == $len or return undef;
    $self->cp += $len;
    return $res;
}

sub push_if {
    my ($self, $cond) = @_;
    push @{$self->ifstack}, $cond;
    $self->iffalse++ unless $cond;
}

sub else_if {
    my ($self) = @_;
    my $top = \$self->ifstack->[-1];
    $self->iffalse += $$top ? 1 : -1;
    $$top = !$$top;
}

sub pop_if {
    my ($self) = @_;
    $self->iffalse-- unless pop @{$self->ifstack};
}

sub ok {
    my $self = shift;
    my $stack = $self->stack;
    return (@$stack == 1 && $stack->[0] eq TRUE && !@{$self->ifstack});
}

1;
