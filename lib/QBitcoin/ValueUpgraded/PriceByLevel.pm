package QBitcoin::ValueUpgraded::PriceByLevel;
use warnings;
use strict;

use Exporter qw(import);
our @EXPORT_OK = qw(@price_by_level);

our @price_by_level = (1000000,999000,(1000000)x4998);

1;

