package QBitcoin::OpenScript;
use warnings;
use strict;

use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::ORM qw(find create :types);
use QBitcoin::Script qw(script_eval);
use QBitcoin::Script::OpCodes qw(:OPCODES);

use constant TABLE => 'open_script';
use constant FIELDS => {
    id   => NUMERIC,
    data => BINARY,
};

mk_accessors(keys %{&FIELDS});

sub store {
    my $class = shift;
    my ($data) = @_;
    # I suppose find()+create() will be more quickly than "insert ignore" + "find" in most cases (when such script already stored)
    return $class->find(data => $data) // $class->create(data => $data);
}

sub script_for_address {
    my $class = shift;
    my ($address) = @_;
    return OP_DUP . OP_HASH160 . $address . OP_EQUALVERIFY . OP_CHECKSIG;
}

sub check_input {
    my ($class) = shift;
    my ($open_script, $close_script) = @_;
    return script_eval($close_script . $open_script);
}

1;
