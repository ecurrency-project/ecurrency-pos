package QBitcoin::ConnectionList;
use warnings;
use strict;

use QBitcoin::Const;

my %CONNECTIONS; # by type and connection id (remote addr + port + direction, unique per connection)

sub list {
    return map { values %$_ } values %CONNECTIONS;
}

sub get {
    my $class = shift;
    my ($type, $id) = @_;
    return $CONNECTIONS{$type}->{$id};
}

# All connections with the given remote address; there may be several:
# multiple nodes behind one NAT address, or mutual simultaneous connects
sub find_ip {
    my $class = shift;
    my ($type, $ip) = @_;
    return grep { $_->addr eq $ip } values %{$CONNECTIONS{$type} // {}};
}

sub connected {
    my $class = shift;
    my @types = @_;
    return grep { $_->state == STATE_CONNECTED } map { values %{$CONNECTIONS{$_}} } @types;
}

sub add {
    my $class = shift;
    my ($connection) = @_;
    $CONNECTIONS{$connection->type_id}->{$connection->id} = $connection;
}

sub del {
    my $class = shift;
    my ($connection) = @_;
    delete $CONNECTIONS{$connection->type_id}->{$connection->id};
}

1;
