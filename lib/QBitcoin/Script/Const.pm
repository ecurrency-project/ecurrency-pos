package QBitcoin::Script::Const;
use warnings;
use strict;

use Exporter qw(import);

# Each boolean has one form: FALSE is the empty element, the same as OP_0 and the number 0
use constant {
    FALSE => "",
    TRUE  => "\x01",
};

our @EXPORT = qw(FALSE TRUE);

1;
