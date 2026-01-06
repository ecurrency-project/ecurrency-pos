package QBitcoin::Script::CheckSig;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Crypto qw(check_sig);
use QBitcoin::Script::Const;
use QBitcoin::Script::Util qw(pack_int unpack_int);

sub cmd_checksig($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 2 or return 0;
    my $pubkey = pop @$stack;
    my $signature = pop @$stack;
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
    @$stack >= $nkeys+1 or return undef;
    my @pubkeys = splice(@$stack, -$nkeys-1);
    my $nsig = unpack_int(pop @$stack) // return undef;
    @$stack >= $nsig or return undef;
    my @sig = splice(@$stack, -$nsig-1);
    $nkeys >= $nsig or return 0;
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
    my $result = check_tx_signature($pubkey, $signature, $state->tx, $state->input_num) ? 1 : 0;
    my $acc_int = unpack_int($accum);
    push @$stack, pack_int($acc_int + $result);
    return undef;
}

sub check_tx_signature {
    my ($pubkey, $signature, $tx, $input_num) = @_;
    my $sighash_type = unpack('C', $signature);
    return check_sig($tx->sign_data($input_num, $sighash_type), substr($signature, 1), $pubkey);
}

1;
