package QBitcoin::RedeemScript;
use warnings;
use strict;

use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::ORM qw(find create :types);
use QBitcoin::Script qw(script_eval op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);

use constant TABLE => 'redeem_script';
use constant FIELDS => {
    id     => NUMERIC,
    hash   => BINARY,
    script => BINARY,
};

mk_accessors(keys %{&FIELDS});

sub store {
    my $class = shift;
    my ($hash) = @_;
    # I suppose find()+create() will be more quickly than "insert ignore" + "find" in most cases (when such script already stored)
    return $class->find(hash => $hash) // $class->create(hash => $hash);
}

sub check_input {
    my ($class) = shift;
    my ($siglist, $redeem_script, $tx, $input_num) = @_;
    my $res = script_eval($siglist, $redeem_script, $tx, $input_num);
    return $res ? 0 : -1; # if script_eval return true then it's ok (0)
}

sub script_type {
    my $class = shift;
    my ($script) = @_;

    # TODO: make proper check (multisig etc)
    # P2PKH:      OP_DUP OP_HASH160 <public_key_hash> OP_EQUALVERIFY OP_CHECKSIG
    # P2PK:       <public_key> OP_CHECKSIG
    # DELEGATION: OP_IF ... OP_ELSE ... OP_ENDIF (see QBitcoin::Script::Delegation)
    return substr($script, 0, 1) eq OP_DUP ? "P2PKH" :
           substr($script, 0, 1) eq OP_IF  ? "DELEGATION" : "P2PK";
}

1;
