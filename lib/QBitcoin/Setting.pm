package QBitcoin::Setting;
use warnings;
use strict;

# Generic key-value store for node-local settings persisted in the database.

use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::ORM qw(find replace delete_by :types);

use constant TABLE => 'setting';

use constant FIELDS => {
    name  => STRING,
    value => STRING,
};

use constant PRIMARY_KEY => 'name';

mk_accessors(qw(name value));

# Return stored value for $name, or undef if not set
sub get {
    my $class = shift;
    my ($name) = @_;
    my $self = $class->find(name => $name)
        or return undef;
    return $self->value;
}

# Insert or replace the value for $name
sub set {
    my $class = shift;
    my ($name, $value) = @_;
    $class->new({ name => $name, value => $value })->replace;
    return;
}

# Remove the setting $name (no-op if absent)
sub unset {
    my $class = shift;
    my ($name) = @_;
    $class->delete_by(name => $name);
    return;
}

1;
