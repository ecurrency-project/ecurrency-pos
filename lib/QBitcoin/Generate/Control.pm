package QBitcoin::Generate::Control;
use warnings;
use strict;

my $GENERATED_TIME;
my $GENERATE_LEVEL;

sub generated_time {
    my $class = shift;
    $GENERATED_TIME = $_[0] if @_;
    return $GENERATED_TIME;
}

# Height of a block that filled a slot empty in our branch before the current timeslot.
# Set by QBitcoin::Block::Receive on a best-branch switch, consumed (and reset) by the
# next QBitcoin::Generate::generate() call, which tries to contest that block on weight.
sub generate_level {
    my $class = shift;
    $GENERATE_LEVEL = $_[0] if @_;
    return $GENERATE_LEVEL;
}

sub generate_new {
    my $class = shift;
    undef $GENERATED_TIME;
}

1;
