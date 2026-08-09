package QBitcoin::Script::Delegation;
use warnings;
use strict;

# The delegated-staking covenant script. Two branches:
# - the owner key spends freely (IF branch, siglist selector "\x01");
# - the delegate key spends only into a stake transaction which pays the full
#   input value back to the same scripthash (ELSE branch, selector "").
# The block reward is not covered by the covenant: whatever the stake
# transaction adds on top of the principal is distributed by the staking node
# (see the reward_addr config option with an optional share).
# Both keys are committed as hash256(pubkey); the full pubkey is provided in
# the siglist at spend time, so the script stays compact even for post-quantum
# keys, and the parties exchange 32-byte hashes instead of full pubkeys.

use QBitcoin::Const;
use QBitcoin::Crypto qw(hash256);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script::Util qw(pack_int);
use QBitcoin::Address qw(address_by_hash);

use Exporter qw(import);
our @EXPORT_OK = qw(
    delegation_script
    delegation_scripthash
    delegation_address
    SELECTOR_OWNER
    SELECTOR_DELEGATE
);

# The last siglist element; OP_IF pops it to select the branch
use constant {
    SELECTOR_OWNER    => "\x01",
    SELECTOR_DELEGATE => "",
};

sub delegation_script($$) {
    my ($owner_pubkeyhash, $delegate_pubkeyhash) = @_;

    return OP_IF
        . OP_DUP . OP_HASH256 . op_pushdata($owner_pubkeyhash) . OP_EQUALVERIFY . OP_CHECKSIG
        . OP_ELSE
        . OP_TX_TYPE . op_pushdata(pack_int(TX_TYPE_STAKE)) . OP_NUMEQUALVERIFY
        . OP_INPUTSCRIPTHASH . OP_DUP . OP_OUTPUTSVALUE . OP_SWAP . OP_INPUTSVALUE
        . OP_GREATERTHANOREQUAL . OP_VERIFY
        . OP_DUP . OP_HASH256 . op_pushdata($delegate_pubkeyhash) . OP_EQUALVERIFY . OP_CHECKSIG
        . OP_ENDIF;
}

sub delegation_scripthash($$) {
    my ($owner_pubkeyhash, $delegate_pubkeyhash) = @_;
    return hash256(delegation_script($owner_pubkeyhash, $delegate_pubkeyhash));
}

sub delegation_address($$) {
    my ($owner_pubkeyhash, $delegate_pubkeyhash) = @_;
    return address_by_hash(delegation_scripthash($owner_pubkeyhash, $delegate_pubkeyhash));
}

1;
