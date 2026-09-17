package QBitcoin::Script::CheckSig;
use warnings;
use strict;

use Role::Tiny;
use List::Util qw(sum0);
use QBitcoin::Const;
use QBitcoin::Crypto qw(check_sig check_sig_hash);
use QBitcoin::Script::Const;
use QBitcoin::Script::Util qw(pack_int unpack_int);
use QBitcoin::BlockchainParams;
use QBitcoin::ProtocolState qw(blockchain_synced);

# Each signature check pays the bytes of the key once and the bytes of the signature twice from the budget
# of the input (its script plus twice its siglist, see script_eval), whatever way they came to the stack:
# the second budget of a siglist byte is there for a key which is hashed and then checked, a signature has
# no second use and is paid in full.
# As in tapscript (BIP-342) an empty signature is not checked and costs nothing:
# it is how a missing signature is given to OP_CHECKSIG/OP_CHECKSIGADD in k-of-n scripts.

sub cmd_checksig($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 2 or return 0;
    my $pubkey = pop @$stack;
    my $signature = pop @$stack;
    if ($signature eq "") {
        push @$stack, FALSE;
        return undef;
    }
    ($state->budget -= length($pubkey) + 2 * length($signature)) >= 0 or return 0;
    push @$stack, check_tx_signature($pubkey, $signature, $state->tx, $state->input_num) ? TRUE : FALSE;
    return undef;
}

sub cmd_checksigverify($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 2 or return 0;
    my $pubkey = pop @$stack;
    my $signature = pop @$stack;
    $signature ne "" or return 0;
    ($state->budget -= length($pubkey) + 2 * length($signature)) >= 0 or return 0;
    return check_tx_signature($pubkey, $signature, $state->tx, $state->input_num) ? undef : 0;
}

# return undef -> script fail
# return 1 -> ok
# return 0 -> signature fail
sub checkmultisig($) {
    my ($state) = @_;
    my $stack = $state->stack;
    @$stack >= 1 or return undef;
    my $nkeys = unpack_int(pop @$stack) // return undef;
    $nkeys >= 0 or return undef;
    @$stack >= $nkeys+1 or return undef;
    my @pubkeys;
    @pubkeys = splice(@$stack, -$nkeys) if $nkeys;
    my $nsig = unpack_int(pop @$stack) // return undef;
    $nsig >= 0 or return undef;
    @$stack >= $nsig or return undef;
    my @sig;
    @sig = splice(@$stack, -$nsig) if $nsig;
    # Bitcoin compatibility: pop an extra value off the stack (which is CHECKMULTISIG's bug)
    # @$stack >= 1 or return undef;
    # pop @$stack eq "" or return undef;
    $nkeys >= $nsig or return 0;
    # Each pubkey may be tried once (a signature which does not match a key skips it),
    # so the cost is up to $nkeys checks whatever $nsig is; all the keys are paid once and the signatures twice
    ($state->budget -= sum0(map { length($_) } @pubkeys) + 2 * sum0(map { length($_) } @sig)) >= 0 or return undef;
    foreach my $sig (@sig) {
        while (1) {
            @pubkeys or return 0;
            last if check_tx_signature(shift(@pubkeys), $sig, $state->tx, $state->input_num);
        }
    }
    return 1;
}

sub cmd_checkmultisig($) {
    my ($state) = @_;
    return unless $state->ifstate;
    push @{$state->stack}, (checkmultisig($state) // return 0) ? TRUE : FALSE;
    return undef;
}

sub cmd_checkmultisigverify($) {
    my ($state) = @_;
    return unless $state->ifstate;
    return checkmultisig($state) ? undef : 0;
}

sub cmd_checksigadd($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 3 or return 0;
    my ($signature, $accum, $pubkey) = splice(@$stack, -3);
    my $acc_int = unpack_int($accum) // return 0;
    my $result = 0;
    if ($signature ne "") {
        ($state->budget -= length($pubkey) + 2 * length($signature)) >= 0 or return 0;
        $result = check_tx_signature($pubkey, $signature, $state->tx, $state->input_num) ? 1 : 0;
    }
    push @$stack, pack_int($acc_int + $result) // return 0;
    return undef;
}

sub check_tx_signature {
    my ($pubkey, $signature, $tx, $input_num) = @_;
    my $sighash_type = unpack('C', $signature);
    my $sign_hash = $tx->sign_hash($input_num, $sighash_type)
        or return 0;
    return check_sig_hash($sign_hash, substr($signature, 1), $pubkey);
}

1;
