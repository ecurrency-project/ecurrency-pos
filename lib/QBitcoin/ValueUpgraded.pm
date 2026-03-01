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
our @EXPORT_OK = qw(level_by_total upgrade_value downgrade_value);

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

sub _downgrade_value_for_level {
    my ($value, $level) = @_;

    return int($value * 1000000 / $price_by_level[$level]);
}

sub downgrade_value {
    my ($value, $upgraded) = @_;

    my $level = level_by_total($upgraded);
    my $btc_value = _downgrade_value_for_level($value, $level);
    $btc_value = $upgraded if $btc_value > $upgraded;
    while ($level > 0 && level_by_total($upgraded - $btc_value) < $level) {
        $level--;
        $btc_value = _downgrade_value_for_level($value, $level);
        $btc_value = $upgraded if $btc_value > $upgraded;
    }
    return $btc_value;
}

1;
