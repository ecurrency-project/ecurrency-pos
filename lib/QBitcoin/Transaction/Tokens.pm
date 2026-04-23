package QBitcoin::Transaction::Tokens;
use strict;
use warnings;

use QBitcoin::Const;
use QBitcoin::Log;
use Role::Tiny;

sub token_hash_str {
    my $self = shift;
    return unpack("H*", substr($self->token_hash // "", 0, 4));
}

sub unpack_token_info {
    my ($self, $data) = @_;
    my %res;
    my $last_attr = 1;
    for (my $i = 0; $i < length($data);) {
        my $type = substr($data, $i, 1);
        my $attr = unpack("C", $type);
        if ($attr <= $last_attr) {
            Warningf("Incorrect token attribute order in transaction %s token %s", $self->hash_str, $self->token_hash_str);
            return undef;
        }
        $last_attr = $attr;
        if ($type eq TOKEN_TXO_TYPE_PERMISSIONS) {
            $i++;
            if (length($data) < $i + 1) {
                Warningf("Incorrect token permissions attribute length in transaction %s token %s", $self->hash_str, $self->token_hash_str);
                return undef;
            }
            $res{permissions} = unpack("C", substr($data, $i, 1));
            $i++;
            next;
        }
        if ($type eq TOKEN_TXO_TYPE_DECIMALS) {
            $i++;
            if (length($data) < $i + 1) {
                Warningf("Incorrect token decimal attribute length in transaction %s token %s", $self->hash_str, $self->token_hash_str);
                return undef;
            }
            my $decimal = unpack("C", substr($data, $i, 1));
            $i++;
            if ($decimal > 18) {
                Warningf("Incorrect token decimal value %u in transaction %s token %s", $decimal, $self->hash_str, $self->token_hash_str);
                return undef;
            }
            $res{decimals} = $decimal;
            next;
        }
        if ($type eq TOKEN_TXO_TYPE_SYMBOL) {
            $i++;
            my $symbol_len = unpack("C", substr($data, $i, 1));
            $i++;
            if (length($data) < $i + $symbol_len) {
                Warningf("Incorrect token symbol attribute length in transaction %s token %s", $self->hash_str, $self->token_hash_str);
                return undef;
            }
            my $symbol = substr($data, $i, $symbol_len);
            $res{symbol} = $symbol;
            $i += $symbol_len;
            next;
        }
        if ($type eq TOKEN_TXO_TYPE_NAME) {
            $i++;
            my $name_len = unpack("C", substr($data, $i, 1));
            $i++;
            if (length($data) < $i + $name_len) {
                Warningf("Incorrect token name attribute length in transaction %s token %s", $self->hash_str, $self->token_hash_str);
                return undef;
            }
            my $name = substr($data, $i, $name_len);
            $res{name} = $name;
            $i += $name_len;
            next;
        }
        last; # Ignore unknown attributes
    }
    return \%res;
}

sub token_tx {
    my $self = shift;

    return undef unless $self->is_tokens;
    return $self unless $self->token_hash;
    my $token_tx = (ref $self)->get_by_hash($self->token_hash)
        or die "No such token transaction " . $self->token_hash_str . " for transaction " . $self->hash_str;
    return $token_tx;
}

sub _load_token_info {
    my $self = shift;

    my $token_tx = $self->token_tx;
    my %res;
    foreach my $out (grep { length($_->data // "") && !$_->is_token_transfer } @{$token_tx->out}) {
        my $data = $self->unpack_token_info($out->data)
            or next;
        foreach my $key (qw(decimals symbol name)) {
            $res{$key} //= $data->{$key} if defined $data->{$key};
        }
    }
    return \%res;
}

sub token_info {
    my $self = shift;
    return $self->{token_info} //= $self->_load_token_info;
}

sub check_tokens_tx {
    my $self = shift;

    my $permissions = 0;
    my $in_value = 0;
    if ($self->token_hash) {
        my $correct_input = 0;
        foreach my $in (grep { ($_->{txo}->token_hash // "") eq $self->token_hash && length($_->{txo}->data // "") } @{$self->in}) {
            my $txo = $in->{txo};
            my $txo_type = substr($txo->data, 0, 1);
            if ($txo_type eq TOKEN_TXO_TYPE_TRANSFER) {
                if (length($txo->data) == 9) {
                    my $transfer_value = unpack("Q<", substr($txo->data, 1, 8));
                    if ($transfer_value == 0) {
                        next;
                    }
                    $correct_input = 1;
                    $in_value += $transfer_value;
                    if ($in_value < $transfer_value) {
                        Warningf("Overflow in token transfer value in transaction %s token %s", $self->hash_str, $self->token_hash_str);
                        return -1;
                    }
                }
                else {
                    # Allow but ignore incorrect token transfer inputs
                    Warningf("Incorect data length for token transfer input in transaction %s token %s", $self->hash_str, $self->token_hash_str);
                }
            }
            elsif ($txo_type eq TOKEN_TXO_TYPE_PERMISSIONS) {
                if (length($txo->data) >= 2) {
                    my $in_permissions = unpack("C", substr($txo->data, 1, 1));
                    $permissions |= $in_permissions;
                    $correct_input = 1;
                }
                else {
                    Warningf("Incorect data length for token permissions input in transaction %s token %s", $self->hash_str, $self->token_hash_str);
                }
            }
        }
        if (!$correct_input) {
            Warningf("No correct token inputs for token %s in transaction %s", $self->token_hash_str, $self->hash_str);
            return -1;
        }
    }
    my $out_value = 0;
    foreach my $out (grep { length($_->data // "") } @{$self->out}) {
        my $txo_type = substr($out->data, 0, 1);
        if ($txo_type eq TOKEN_TXO_TYPE_TRANSFER) {
            if (length($out->data) == 1+8) {
                my $transfer_value = unpack("Q<", substr($out->data, 1, 8));
                $out_value += $transfer_value;
                if ($out_value < $transfer_value) {
                    Warningf("Overflow in token transfer value in transaction %s token %s", $self->hash_str, $self->token_hash_str);
                    return -1;
                }
            }
            else {
                Warningf("Incorect data length for token transfer output in transaction %s token %s", $self->hash_str, $self->token_hash_str);
                return -1;
            }
        }
        else {
            # Control attributes
            my $data = $self->unpack_token_info($out->data)
                or return -1;
            if ($self->token_hash) {
                if ($data->{permissions} && ($data->{permissions} & ~$permissions)) {
                    Warningf("Attempt to gain token %s permission in transaction %s", $self->token_hash_str, $self->hash_str);
                    return -1;
                }
                if ($data->{decimals} || $data->{symbol} || $data->{name}) {
                    Warningf("Attempt to change token %s attributes in transaction %s", $self->token_hash_str, $self->hash_str);
                    return -1;
                }
            }
        }
    }
    if ($self->token_hash && $out_value > $in_value && !($permissions & TOKEN_PERMISSION_MINT)) {
        Warningf("Token transfer output value %lu exceeds input value %lu in transaction %s token %s",
            $out_value, $in_value, $self->hash_str, $self->token_hash_str);
        return -1;
    }
    return 0;
}

sub token_output_as_hashref {
    my $self = shift;
    my ($out) = @_;
    my $res = { token_id => unpack("H*", $self->token_hash || $self->hash) };
    if (length($out->data // "")) {
        if ($out->is_token_transfer) {
            $res->{token_amount} = unpack("Q<", substr($out->data, 1, 8));
            my $decimals;
            if (my $token_info = $self->token_info) {
                $decimals = $token_info->{decimals};
            }
            $res->{token_decimals} = $decimals // TOKEN_DEFAULT_DECIMALS;
        }
        elsif (my $token_info = $self->unpack_token_info($out->data)) {
            if ($token_info->{permissions}) {
                $res->{token_permissions} = "0x" . unpack("H2", substr($out->data, 1, 1));
            }
            foreach my $key (qw(decimals symbol name)) {
                $res->{"token_$key"} = $token_info->{$key} if defined $token_info->{$key};
            }
        }
    }
    return $res;
}

1;
