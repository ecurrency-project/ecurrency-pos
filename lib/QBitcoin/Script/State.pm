package QBitcoin::Script::State;
use warnings;
use strict;

use QBitcoin::Script::Const;

sub new {
    my $class = shift;
    my ($script, $stack, $tx, $input_num, $budget) = @_;
    # script, cp, stack, false if-branches, if-stack, alt-stack, tx, input_num, budget, frames
    return bless [$script, 0, $stack // [], 0, [], [], $tx, $input_num, $budget, []], $class;
}

sub script  :lvalue { $_[0]->[0] }
sub cp      :lvalue { $_[0]->[1] }
sub stack     { $_[0]->[2] }
sub iffalse :lvalue { $_[0]->[3] } # number of false entries in ifstack
sub ifstack   { $_[0]->[4] }
sub altstack  { $_[0]->[5] }
sub tx        { $_[0]->[6] }
sub input_num { $_[0]->[7] }
sub budget  :lvalue { $_[0]->[8] } # units left of the input budget, shared by all exec levels (see script_eval)
sub frames    { $_[0]->[9] } # enclosing exec levels, 5 entries each (see push_frame)

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

# OP_EXEC runs a script with its own position, if-state and altstack over the shared stack and budget.
# The level is a frame of the state and not a nested execute(), so the nesting is not a perl recursion:
# a self-replicating element nests as deep as the budget allows (see script_eval)
sub push_frame {
    my ($self, $script) = @_;
    push @{$self->[9]}, @$self[0, 1, 3, 4, 5];
    @$self[0, 1, 3, 4, 5] = ($script, 0, 0, [], []);
}

# Return to the enclosing level when the executed script ends; false at the top level
sub pop_frame {
    my ($self) = @_;
    @{$self->[9]} or return 0;
    @$self[0, 1, 3, 4, 5] = splice(@{$self->[9]}, -5);
    return 1;
}

sub ok {
    my $self = shift;
    my $stack = $self->stack;
    return (@$stack == 1 && $stack->[0] eq TRUE && !@{$self->ifstack});
}

1;
