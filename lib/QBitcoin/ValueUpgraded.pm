package QBitcoin::ValueUpgraded;
use warnings;
use strict;

use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::Const;
use QBitcoin::ORM qw(find create :types);
use QBitcoin::ValueUpgraded::PriceByLevel qw(@price_by_level);

use Exporter qw(import);
our @EXPORT_OK = qw(level_by_total upgrade_value);

use constant TABLE => 'value_upgraded';

use constant PRIMARY_KEY => 'block_height';

use constant FIELDS => {
    block_height => NUMERIC,
    value        => NUMERIC,
    total        => NUMERIC,
};

mk_accessors(keys %{&FIELDS});

sub level_by_total {
    my ($total) = @_;

    return int($total * 5000 / MAX_VALUE);
}

sub price_by_level {
    my ($level) = @_;

    # return 0.999**$level;
    # Avoid floating point arithmetic
    return $price_by_level[$level];
}

sub upgrade_value {
    my ($value, $level) = @_;

    return int($value * $price_by_level[$level] / 1000000);
}

1;
