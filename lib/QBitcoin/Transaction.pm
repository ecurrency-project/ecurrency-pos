package QBitcoin::Transaction;
use warnings;
use strict;

use JSON::XS;
use List::Util qw(sum0);
use Digest::SHA qw(sha256);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::ORM qw(find replace :types);
use QBitcoin::TXO;

use constant FIELDS => {
    id           => NUMERIC, # db primary key for reference links
    hash         => BINARY,
    block_height => NUMERIC,
    fee          => NUMERIC,
    size         => NUMERIC,
};

use constant TABLE => 'transaction';

use constant ATTR => qw(
    coins_upgraded
    received_time
    in
    out
);

mk_accessors(keys %{&FIELDS}, ATTR);

my %TRANSACTION;

my $JSON = JSON::XS->new;

sub get_by_hash {
    my $class = shift;
    my ($tx_hash) = @_;

    return ($class->get($tx_hash) // $class->find(hash => $tx_hash));
}

sub get {
    my $class = shift;
    my ($tx_hash) = @_;

    return $TRANSACTION{$tx_hash};
}

sub mempool_list {
    my $class = shift;
    return grep { !$_->block_height && $_->fee >= 0 } values %TRANSACTION;
}

# We never drop existing transaction b/c it's possible its txo already spend by another one
# This method calls when the transaction stored in the database and is not needed in memory anymore
# TXO (input and output) will free from %TXO hash by DESTROY() method, they have weaken reference for this
sub free {
    my $self = shift;
    delete $TRANSACTION{$self->hash};
}

sub store {
    my $self = shift;
    my ($height) = @_;
    local $self->{block_height} = $height;
    # we are in sql transaction
    $self->replace();
    my $class = ref $self;
    foreach my $in (@{$self->in}) {
        my $txo = $in->{txo};
        $txo->store_spend($self),
    }
    foreach my $num (0 .. @{$self->out}-1) {
        my $txo = $self->out->[$num];
        $txo->store($self);
    }
    # TODO: store tx data (smartcontract)
}

sub hash_out {
    my $arg = shift;
    my $hash = ref($arg) ? $arg->hash : $arg;
    # TODO: return full hash
    return unpack("H*", substr($hash, 0, 4));
}

sub serialize {
    my $self = shift;
    # TODO: pack as binary data
    # TODO: add transaction signature
    return $JSON->encode({
        in  => [ map { serialize_input($_) } @{$self->in}  ],
        out => [ map { $_->serialize       } @{$self->out} ],
    }) . "\n";
}

sub serialize_input {
    my $in = shift;
    return {
        tx_out       => $in->{txo}->tx_in,
        num          => $in->{txo}->num,
        close_script => $in->{close_script},
    };
}

sub deserialize {
    my $class = shift;
    my ($tx_data) = @_;
    my $decoded = eval { $JSON->decode($tx_data) };
    if (!$decoded) {
        Warningf("Incorrect transaction data: %s", $@);
        return undef;
    }
    my $hash = $class->calculate_hash($tx_data);
    my $out  = create_outputs($decoded->{out}, $hash);
    my $in   = load_inputs($decoded->{in}, $hash);
    my $self = $class->new(
        in            => $in,
        out           => $out,
        hash          => $hash,
        size          => length($tx_data),
        received_time => time(),
    );
    if ($class->calculate_hash($self->serialize) ne $hash) {
        Warningf("Incorrect serialized transaction has different hash");
        return undef;
    }
    $self->validate() == 0
        or return undef;

    QBitcoin::TXO->save_all($self->hash, $out);
    $self->fee = sum0(map { $_->value } @$out) - sum0(map { $_->{txo}->value } @$in) + ($self->coins_upgraded // 0);

    return $self;
}

sub create_outputs {
    my ($out, $hash) = @_;
    my @txo;
    foreach my $num (0 .. $#$out) {
        my $txo = QBitcoin::TXO->new({
            tx_in       => $hash,
            num         => $num,
            value       => $out->[$num]->{value},
            open_script => $out->[$num]->{open_script},
        });
        push @txo, $txo;
        if ($txo->is_my) {
            $txo->add_my_utxo();
        }
    }
    return \@txo;
}

sub load_inputs {
    my ($inputs, $hash) = @_;

    # tx inputs are not sorted in the database, so sort them here for get deterministic transaction hash
    my @loaded_inputs;
    my @need_load_txo;
    foreach my $in (@$inputs) {
        if (my $txo = QBitcoin::TXO->get($in)) {
            push @loaded_inputs, {
                txo          => $txo,
                close_script => $in->{close_script},
            };
        }
        else {
            push @need_load_txo, $in;
        }
    }

    if (@need_load_txo) {
        QBitcoin::TXO->load(@need_load_txo);
        foreach my $in (@need_load_txo) {
            if (my $txo = QBitcoin::TXO->get($in)) {
                push @loaded_inputs, {
                    txo          => $txo,
                    close_script => $in->{close_script},
                };
            }
            else {
                Warningf("input %s:%u not found in transaction %s",
                    hash_out($in->{tx_out}), $in->{num}, hash_out($hash));
                return undef;
            }
        }
    }
    return [ sort { _cmp_inputs($a, $b) } @loaded_inputs ];
}

sub _cmp_inputs {
    my ($in1, $in2) = @_;
    return $in1->{txo}->tx_in cmp $in2->{txo}->tx_in || $in1->{txo}->num <=> $in2->{txo}->num;
}

sub calculate_hash {
    my $class = shift;
    my ($tx_data) = @_;
    return sha256($tx_data);
}

sub validate_coinbase {
    my $self = shift;
    if (@{$self->out} != 1) {
        Warningf("Incorrect coinbase transaction %s: %u outputs, must be 1", $self->hash_out, scalar @{$self->out});
        return -1;
    }
    # TODO: Get and validate information about btc upgrade from $self->data
    # Each upgrade should correspond fixed and deterministic tx hash for qbitcoin
    my $coins = $self->out->[0]->value;
    $self->coins_upgraded = $coins; # for calculate fee
    return 0;
}

sub validate {
    my $self = shift;
    if (!@{$self->in}) {
        return $self->validate_coinbase;
    }
    # Transaction must contains least one output (can't spend all inputs as fee)
    if (!@{$self->out}) {
        Warningf("No outputs in transaction %s", $self->hash_out);
        return -1;
    }
    foreach my $out (@{$self->out}) {
        if ($out->value < 0 || $out->value > MAX_VALUE) {
            Warningf("Incorrect output value in transaction %s", $self->hash_out);
            return -1;
        }
    }
    my $class = ref $self;
    my @stored_in;
    my $input_value = 0;
    foreach my $in (@{$self->in}) {
        $input_value += $in->{txo}->value;
        if ($in->{txo}->check_script($in->{close_script}) != 0) {
            Warningf("Unmatched close script for input %s:%u in transaction %s",
                unpack("H*", $in->{txo}->tx_in), $in->{txo}->num, $self->hash_out);
            return -1;
        }
    }
    if ($input_value <= 0) {
        Warning("Zero input in transaction %s", $self->hash_out);
        return -1;
    }
    # TODO: Check that transaction is signed correctly
    return 0;
}

sub receive {
    my $self = shift;
    $TRANSACTION{$self->hash} = $self;
    return 0;
}

sub on_load {
    my $self = shift;
    $TRANSACTION{$self->hash} = $self;
    # Load TXO for inputs and outputs
    my @outputs = QBitcoin::TXO->load_outputs($self);
    my @inputs;
    foreach my $txo (QBitcoin::TXO->load_inputs($self)) {
        push @inputs, {
            txo          => $txo,
            close_script => $txo->close_script,
        };
        # `close_script` saved as transaction $in->{close_script}, not in the $txo object
        $txo->close_script = undef;
        # `tx_out` will be set during processing this block by receive() and including it in the best branch
        # if `tx_out` will be already set here, processing this block will fails as double-spend
        $txo->tx_out = undef;
    }
    $self->in  = [ sort { _cmp_inputs($a, $b) } @inputs ];
    $self->out = \@outputs;
    $self->received_time = time_by_height($self->block_height); # for possible unconfirm the transaction
    return $self;
}

sub unconfirm {
    my $self = shift;
    $self->block_height = undef;
    foreach my $in (@{$self->in}) {
        my $txo = $in->{txo};
        $txo->tx_out = undef;
        if ($txo->is_my) {
            $txo->add_my_utxo();
        }
    }
}

sub stake_weight {
    my $self = shift;
    my ($block_height) = @_;
    my $weight = 0;
    my $class = ref $self;
    foreach my $in (map { $_->{txo} } @{$self->in}) {
        if (my $tx = $class->get_by_hash($in->tx_in)) {
            if (!$tx->block_height) {
                Warningf("Can't get stake_weight for %s with unconfirmed input %s:%u",
                    $self->hash_out, unpack("H*", $in->tx_in), $in->num);
                return undef;
            }
            $weight += $in->value * ($block_height - $tx->block_height);
        }
        else {
            # tx generated this txo should be loaded during tx validation
            Warningf("No input transaction %s for txo", unpack("H*", $in->tx_in));
            return undef;
        }
    }
    return $weight;
}

1;
