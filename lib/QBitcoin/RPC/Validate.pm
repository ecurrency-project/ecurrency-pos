package QBitcoin::RPC::Validate;
use warnings;
use strict;

use Role::Tiny;
use JSON::XS;
use Scalar::Util qw(looks_like_number);
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Config;
use QBitcoin::Address qw(wif_to_pk);
use QBitcoin::Accessors qw(mk_accessors);

mk_accessors(qw(validate_message));

my $JSON = JSON::XS->new;

my %SPEC = (
    height         => qr/^(?:0|[1-9][0-9]{0,9})\z/,
    blockhash      => qr/^[0-9a-f]{64}\z/,
    txid           => qr/^[0-9a-f]{64}\z/,
    command        => qr/^[a-z]{2,64}\z/,
    verbosity      => qr/^[12]\z/,
    hexstring      => qr/^(?:[0-9a-f][0-9a-f])+\z/,
    nblocks        => qr/^[1-9][0-9]{0,9}\z/,
    hash_or_height => qr/^(?:0|[1-9][0-9]{0,9}|[0-9a-f]{64})\z/,
    minconf        => qr/^(?:0|[1-9][0-9]{0,9})\z/,
    conf_target    => qr/^[1-9][0-9]?\z/,
    estimate_mode  => qr/^(?:economical|conservative)\z/i,
    token          => qr/^[0-9a-f]{64}\z/,
    verbose        => \&validate_boolean,
    address        => \&validate_address,
    inputs         => \&validate_inputs,
    outputs        => \&validate_outputs,
    privatekeys    => \&validate_privkeys,
    privkey        => \&validate_privkey,
    address_type   => \&validate_address_type,
);

sub validate {
    my $self = shift;
    my @spec = split(/\s+/, $_[0]); 
    my $args = $self->args;

    if (@$args > @spec) {
        return $self->incorrect_params("Too many params", \@spec);
    }
    my $optional;
    for (my $i = 0; $i < @$args; $i++) {
        my $arg = $args->[$i];
        my $arg_name = $spec[$i];
        if (substr($arg_name, -1) eq '?') {
            $optional = 1;
        }
        elsif ($optional) {
            # Mandatory params cannot be after optional
            die "Incorrect params spec for " . $self->cmd;
        }
        my $spec_arg = $arg_name;
        $spec_arg =~ s/\?$//;
        $spec_arg =~ s@.*/@@;
        $arg_name =~ s@[:?/].*@@;
        if (my $rule = $SPEC{$spec_arg}) {
            if (ref($rule) eq 'Regexp') {
                $arg =~ $rule
                    or return $self->incorrect_params("Incorrect parameter '$arg_name'", \@spec);
            }
            elsif (ref($rule) eq 'CODE') {
                $self->validate_message = undef;
                $rule->($args->[$i], $self) # arg may be modified by validation function
                    or return $self->incorrect_params($self->validate_message // "Incorrect parameter '$arg_name'", \@spec);
            }
            else {
                Warningf("Unknown type of validation rule for [%s]", $spec_arg);
            }
        }
        else {
            Warningf("No validation rule for [%s]", $spec_arg);
        }
    }
    for (my $i = @$args; $i < @spec; $i++) {
        next if substr($spec[$i], -1) eq '?';
        if ($optional) {
            die "Incorrect params spec for " . $self->cmd;
        }
        else {
            return $self->incorrect_params("Mandatory params missing", \@spec);
        }
    }
    return 0;
}

sub validate_boolean {
    my $value = $_[0];
    return 1 if ref($value) eq ref(FALSE);
    if (ref($value) eq "SCALAR") {
        $_[0] = $$value eq "1" ? TRUE : $$value eq "0" ? FALSE : return 0;
        return 1;
    }
    return 0 if ref($value);
    return 0 unless $value =~ /^(?:0|1|true|false)\z/;
    $value = 0 if $value eq "false";
    $_[0] = $value ? TRUE : FALSE;
    return 1;
}

sub validate_address {
    $_[0] =~ ($config->{testnet} ? ADDRESS_TESTNET_RE : ADDRESS_RE);
}

sub is_amount {
    my $amount = shift;
    looks_like_number($amount) or return 0;
    $amount >= 0 or return 0;
    $amount * DENOMINATOR <= MAX_VALUE or return 0;
    return 1;
}

sub validate_txid {
    my $value = $_[0];
    $value =~ /^[0-9a-f]{64}\z/
        or return 0;
    return 1;
}

sub validate_vout {
    my $value = $_[0];
    $value =~ /^(?:0|[1-9][0-9]{0,5})\z/
        or return 0;
    $value <= 65535
        or return 0;
    return 1;
}

sub validate_inputs {
    my $value = $_[0];
    my $inputs = ref($value) ? $value : eval { $JSON->decode($value) };
    if (!$inputs || ref($inputs) ne "ARRAY") {
        return 0;
    }
    foreach my $in (@$inputs) {
        (defined($in->{txid}) && !ref($in->{txid}) && validate_txid($in->{txid})) or return 0;
        (defined($in->{vout}) && !ref($in->{vout}) && validate_vout($in->{vout})) or return 0;
        keys(%$in) == 2 or return 0;
    }
    $_[0] = $inputs;
    return 1;
}

sub validate_outputs {
    my $value = $_[0];
    my $outputs = ref($value) ? $value : eval { $JSON->decode($value) };
    if (!$outputs || (ref($outputs) ne "ARRAY" && ref($outputs) ne "HASH")) {
        return 0;
    }
    $outputs = [ $outputs ] if ref($outputs) eq "HASH";
    foreach my $out (@$outputs) {
        ref($out) eq "HASH" or return 0;
        my $address_count = 0;
        my $token = undef;
        foreach my $key (keys %$out) {
            if (validate_address($key)) {
                (defined($out->{$key}) && !ref($out->{$key}) && is_amount($out->{$key}))
                    or return 0;
                $address_count++;
            }
            elsif ($key =~ /^[0-9a-f]{64}\z/ || $key eq "") {
                return 0 if defined $token; # only one token key allowed
                $token = $key;
            }
            else {
                return 0;
            }
        }
        return 0 if defined($token) && $address_count != 1;
    }
    $_[0] = $outputs;
    return 1;
}

sub validate_privkey {
    eval { wif_to_pk($_[0]) }
        or return 0;
    return 1;
}

sub validate_privkeys {
    my $value = $_[0];
    my $privkeys = ref($value) ? $value : eval { $JSON->decode($value) };
    if (!$privkeys || ref($privkeys) ne "ARRAY") {
        return 0;
    }
    foreach my $privkey (@$privkeys) {
        ref($privkey) eq "" or return 0;
        eval { wif_to_pk($privkey) }
            or return 0;
    }
    $_[0] = $privkeys;
    return 1;
}

sub validate_address_type {
    my $value = $_[0]
        or return 0;
    my $algo = CRYPT_ALGO_BY_NAME->{$value}
        or return 0;
    $_[0] = $algo;
}

sub incorrect_params {
    my $self = shift;
    my ($message, $spec) = @_;
    $self->response_error($message, ERR_INVALID_PARAMS, $self->brief($self->cmd) . "\n" . $self->help($self->cmd));
    return -1;
}

sub brief {
    my $self = shift;
    my ($cmd) = @_;
    my $spec = $self->params($cmd);
    my $params = $cmd;
    my $optional = 0;
    foreach my $arg (split(/\s+/, $spec)) {
        $params .= " ";
        if (substr($arg, -1) eq "?") {
            $params .= "[ ";
            $optional++;
        }
        $arg =~ s@[/:?].*@@;
        $params .= "<$arg>";
    }
    $params .= " " . "]" x $optional if $optional;
    return $params;
}

1;
