package QBitcoin::Tag;
use warnings;
use strict;

use QBitcoin::ORM qw(find create :types);
use QBitcoin::Accessors qw(mk_accessors new);

use constant TABLE => 'tag';

use constant FIELDS => {
    id  => NUMERIC,
    tag => STRING,
};

mk_accessors(qw(id tag));

sub get_or_create {
    my ($class, $tag_name) = @_;
    my $existing = $class->find(tag => $tag_name);
    return $existing if $existing;
    return $class->create({ tag => $tag_name });
}

1;
