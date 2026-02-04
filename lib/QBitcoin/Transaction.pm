package QBitcoin::Transaction;
use warnings;
use strict;

use Tie::IxHash;
use List::Util qw(sum0);
use Scalar::Util qw(refaddr);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ORM qw(find fetch create delete :types);
use QBitcoin::Crypto qw(hash256);
use QBitcoin::TXO;
use QBitcoin::Coinbase;
use QBitcoin::ValueUpgraded qw(level_by_total);
use QBitcoin::ConnectionList;
use Bitcoin::Serialized;

use Role::Tiny::With;
with 'QBitcoin::Transaction::Signature';

use constant FIELDS => {
    id           => NUMERIC, # db primary key for reference links
    hash         => BINARY,
    block_height => NUMERIC,
    block_pos    => NUMERIC,
    fee          => NUMERIC,
    size         => NUMERIC,
    tx_type      => NUMERIC,
    token_id     => NUMERIC,
};

use constant TABLE => 'transaction';

use constant ATTR => qw(
    received_time
    received_from
    in
    out
    up
    input_pending
    input_detached
    blocks
    block_sign_data
    rcvd
    in_raw
    block_time
    drop_immune
    upgrade_level
    token_hash
);

mk_accessors(keys %{&FIELDS}, ATTR);

my %TRANSACTION;      # in-memory cache transaction objects by tx_hash
my %TX_SEQ_DEPENDS;   # txo depends min_rel_time or min_rel_block_height
my %PENDING_INPUT_TX; # 2-level hash $pending_hash => $hash; value - transaction object
my %PENDING_TX_INPUT; # hash of pending transaction objects by tx_hash
tie(%PENDING_TX_INPUT, 'Tie::IxHash'); # Ordered by age, to remove oldest

END {
    # Free all references to txo for graceful free %TXO hash
    undef %TRANSACTION;
};

sub get_by_hash { # cached or load from database
    my $class = shift;
    my ($tx_hash) = @_;

    return $class->get($tx_hash) // $class->find(hash => $tx_hash);
}

# return block_height or undef for unknown transaction, -1 for mempool (unconfirmed)
sub check_by_hash {
    my $class = shift;
    my ($tx_hash) = @_;

    my $block_height;
    if (my $tx = $class->get($tx_hash)) {
        $block_height = $tx->block_height // -1;
    }
    elsif (my ($tx_hash) = $class->fetch(hash => $tx_hash)) {
        $block_height = $tx_hash->{block_height};
    }
    else {
        return undef;
    }
    return $block_height || "0e0";
}

sub get { # only cached
    my $class = shift;
    my ($tx_hash) = @_;

    return $TRANSACTION{$tx_hash};
}

sub add_to_cache {
    my $self = shift;

    if (exists $TRANSACTION{$self->hash}) {
        die "receive already loaded transaction " . $self->hash_str . "\n";
    }
    $TRANSACTION{$self->hash} = $self;

    foreach my $in (@{$self->in}) {
        $in->{txo}->spent_add($self);
    }
}

sub delete_from_cache {
    my $self = shift;

    foreach my $in (@{$self->in}) {
        my $txo = $in->{txo};
        if (delete $TX_SEQ_DEPENDS{$txo->tx_in}->{$self->hash}) {
            delete $TX_SEQ_DEPENDS{$txo->tx_in} unless %{$TX_SEQ_DEPENDS{$txo->tx_in}};
        }
    }
    delete $TRANSACTION{$self->hash};
}

sub save {
    my $self = shift;

    $self->add_to_cache();

    foreach my $in (@{$self->in}) {
        # Exclude from my utxo spent unconfirmed, do not use them for stake transactions
        $in->{txo}->del_my_utxo() if $self->fee >= 0 && $in->{txo}->is_my;
    }

    return 0;
}

sub receive {
    my $self = shift;

    if ($self->validate_hash() or $self->validate() or $self->save()) {
        foreach my $in (@{$self->in}) {
            $in->{txo}->spent_del($self);
        }
        return -1;
    }

    if ($self->up) {
        $self->up->store; # and update $self->up->tx_out here if already stored
    }

    Debugf("Process tx %s fee %li size %u", $self->hash_str, $self->fee, $self->size);
    $self->process_pending();
    return 0;
}

sub received_from_peer {
    my $self = shift;
    return $self->received_from && $self->received_from->can('peer');
}

sub process_pending {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my $self = shift;
    if (my $pending = delete $PENDING_INPUT_TX{$self->hash}) {
        foreach my $tx (values %$pending) {
            if (!$tx->add_pending_tx($self)) {
                $tx->drop();
                next;
            }
            if (!$tx->is_pending) {
                Debugf("Process transaction %s pending for %s", $tx->hash_str, $self->hash_str);
                foreach my $in (@{$tx->in}) {
                    $in->{txo}->spent_confirm($tx);
                }
                $tx->calculate_fee();
                $tx->received_from->process_tx($tx);
            }
        }
    }
}

sub add_pending_tx {
    my $self = shift;
    my ($tx) = @_;

    if ($self->{input_pending} && (my $tx_in = delete $self->{input_pending}->{$tx->hash})) {
        foreach my $in (grep { defined($_) } values %$tx_in) {
            my $txo = QBitcoin::TXO->get($in);
            if (!$txo) {
                Warningf("Transaction %s has no output %u for tx %s input",
                    $self->hash_str($in->{tx_out}), $in->{num}, $self->hash_str);
                return undef;
            }
            if ($txo->set_redeem_script($in->{redeem_script}) != 0) {
                Warningf("Incorrect redeem_script for input %s on %s", $txo->tx_in_str, $self->hash_str);
                return undef;
            }
            if ($tx->is_pending) {
                $self->{input_detached}->{$tx->hash} //= [];
                push @{$self->{input_detached}->{$tx->hash}}, { txo => $txo, siglist => $in->{siglist} };
            }
            else {
                push @{$self->in}, { txo => $txo, siglist => $in->{siglist} };
            }
            $txo->spent_add($self);
        }
        if (!%{$self->{input_pending}}) {
            delete $self->{input_pending};
        }
    }
    elsif ($self->{input_detached} && ($tx_in = delete $self->{input_detached}->{$tx->hash})) {
        push @{$self->in}, @$tx_in;
        if (!%{$self->{input_detached}}) {
            delete $self->{input_detached};
        }
    }
    if (!($self->{input_pending} && %{$self->{input_pending}}) && !($self->{input_detached} && %{$self->{input_detached}})) {
        $self->in = [ sort { _cmp_inputs($a, $b) } @{$self->in} ];
        delete $PENDING_TX_INPUT{$self->hash};
    }
    $self->received_from->has_pending(1) if $self->received_from;
    return $self;
}

sub add_to_block {
    my $self = shift;
    my ($block) = @_;
    $self->{blocks}->{$block->hash} = 1;
    $self->{received_time} //= $block->time; # for transactions loaded from database, they may be unconfirmed and go to mempool
}

sub del_from_block {
    my $self = shift;
    my ($block) = @_;
    delete $self->{blocks}->{$block->hash};
    if (!%{$self->{blocks}}) {
        if (defined($self->block_height)) {
            # Confirmed, not mempool
            $self->free();
        }
        elsif ($self->is_stake) {
            $self->drop();
        }
    }
}

sub in_blocks {
    my $self = shift;
    return $self->{blocks} ? (keys %{$self->{blocks}}) : ();
}

sub mempool_list {
    my $class = shift;
    return grep { !defined($_->block_height) && $_->fee >= 0 } values %TRANSACTION;
}

# This method calls when the confirmed transaction stored into the database and is not needed in memory anymore
# TXO (input and output) will free from %TXO hash by DESTROY() method, they have weaken reference for this
sub free {
    my $self = shift;
    return if $self->in_blocks;
    if (defined($self->block_height) && !$self->id) {
        die "Attempt to free not stored transaction " . $self->hash_str . " confirmed in block " . $self->block_height . "\n";
    }
    foreach my $in (@{$self->in}) {
        $in->{txo}->spent_del($self);
    }
    $self->delete_from_cache;
}

# Drop the transaction from mempool and all dependent transactions if any
sub drop {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my $self = shift;
    if (!$TRANSACTION{$self->hash} && !exists $PENDING_TX_INPUT{$self->hash}) {
        Debugf("Attempt to drop not cached transaction %s (already dropped?)", $self->hash_str);
        return 1;
    }
    if (defined($self->block_height)) {
        Errf("Attempt to drop confirmed transaction %s, block height %u", $self->hash_str, $self->block_height);
        die "Can't drop confirmed transaction " . $self->hash_str . "\n";
    }
    if ($self->in_blocks) {
        Debugf("Transaction %s is in loaded unconfirmed blocks, do not drop", $self->hash_str);
        return;
    }
    if ($self->drop_immune) {
        Debugf("Transaction %s is drop-immune, do not drop", $self->hash_str);
        return;
    }
    foreach my $out (@{$self->out}) {
        foreach my $dep_tx ($out->spent_list, $out->spent_pending) {
            Infof("Drop transaction %s dependent on %s", $dep_tx->hash_str, $self->hash_str);
            $dep_tx->drop()
                or return; # Do not drop the tx if any dependent transaction is in unconfirmed block, at any depth
        }
    }
    foreach my $in (@{$self->in}, map { @$_ } values %{$self->input_detached // {}}) {
        $in->{txo}->spent_del($self);
    }
    if ($self->is_pending) {
        Debugf("Drop pending transaction %s", $self->hash_str);
        delete $PENDING_TX_INPUT{$self->hash};
        foreach my $tx_in (keys(%{$self->input_detached // {}}), keys(%{$self->input_pending // {}})) {
            delete $PENDING_INPUT_TX{$tx_in}->{$self->hash};
            delete $PENDING_INPUT_TX{$tx_in} unless %{$PENDING_INPUT_TX{$tx_in}};
        }
    }
    else {
        Debugf("Drop transaction %s from mempool", $self->hash_str);
        foreach my $out (@{$self->out}) {
            $out->del_my_utxo if $out->is_my;
        }
        foreach my $txo (map { $_->{txo} } @{$self->in}) {
            if ($txo->is_my && $txo->unspent) {
                # add to my_utxo list only if it was confirmed in the best branch
                my $class = ref $self;
                my $tx_in = $class->get($txo->tx_in);
                if (!$tx_in || defined($tx_in->block_height)) {
                    $txo->add_my_utxo;
                }
            }
        }
        $self->delete_from_cache;
    }
    return 1;
}

# Remove unneeded stake transactions and transactions with confirmed spent inputs
sub cleanup_mempool {
    my $class = shift;
    my @tx = grep { !$_->in_blocks && !defined($_->block_height) } values %TRANSACTION;
    foreach my $tx (@tx) {
        if ($tx->is_stake) {
            if ($tx->drop()) {
                Infof("Drop stake tx %s not related to any known blocks", $tx->hash_str);
            }
            next;
        }
        if (UPGRADE_POW && $tx->is_coinbase) {
            if ($tx->up->tx_out) {
                if ($tx->drop()) {
                    Infof("Drop coinbase tx %s from mempool b/c it was already spent in %s",
                        $tx->hash_str, $tx->hash_str($tx->up->tx_out));
                }
            }
            next;
        }
        my $spent_txo;
        foreach my $in (@{$tx->in}) {
            my $txo = $in->{txo};
            if ($txo->tx_out) {
                # Already confirmed spent
                $spent_txo = $txo;
                last;
            }
        }
        if ($spent_txo) {
            if ($tx->drop()) {
                Infof("Drop mempool tx %s b/c input %s:%u was already spent in %s",
                    $tx->hash_str, $spent_txo->tx_in_str, $spent_txo->num, $tx->hash_str($spent_txo->tx_out));
            }
            next;
        }
    }
}

sub store {
    my $self = shift;
    $self->is_cached or die "store not cached transaction " . $self->hash_str;
    # we are in sql transaction
    if ($self->is_tokens && $self->token_hash) {
        my ($tokens_tx) = QBitcoin::Transaction->fetch(hash => $self->token_hash);
        $self->token_id = $tokens_tx->{id};
    }
    $self->create();
    foreach my $in (@{$self->in}) {
        $in->{txo}->store_spend($self),
    }
    foreach my $txo (@{$self->out}) {
        $txo->store($self);
    }
    if (my $coinbase = $self->up) {
        $coinbase->store_published($self);
    }
}

sub hash_str {
    my $arg = pop;
    my $hash = ref($arg) ? $arg->hash : $arg;
    return unpack("H*", substr($hash, 0, 4));
}

sub token_hash_str {
    my $self = shift;
    return unpack("H*", substr($self->token_hash, 0, 4));
}

sub serialize {
    my $self = shift;

    my $data = pack("c", $self->tx_type);
    $data .= varstr($self->token_hash // "") if $self->is_tokens;
    $data .= varint(scalar @{$self->in});
    $data .= serialize_input($_) foreach @{$self->in};
    $data .= varint(scalar @{$self->out});
    $data .= serialize_output($_) foreach @{$self->out};
    if (my $coinbase = $self->is_coinbase) {
        $data .= UPGRADE_POW ? varint($self->upgrade_level) . serialize_coinbase($self->up) : pack("Q<", $self->coins_created);
    }
    return $data;
}

sub serialize_unsigned {
    my $self = shift;

    my $data = pack("c", $self->tx_type);
    $data .= varstr($self->token_hash // "") if $self->is_tokens;
    $data .= varint(scalar @{$self->in});
    if ($self->in_raw) {
        $data .= serialize_input_raw($_) foreach @{$self->in_raw};
    }
    else {
        $data .= serialize_input_unsigned($_) foreach @{$self->in};
    }
    $data .= varint(scalar @{$self->out});
    $data .= serialize_output($_) foreach @{$self->out};
    return $data;
}

sub sign_data {
    my $self = shift;
    my ($input_num, $sighash_type) = @_;

    my $data;
    if (!defined($data = $self->{sign_data}->[$sighash_type])) {
        $data = pack("C", $self->tx_type);
        if ($sighash_type & SIGHASH_ANYONECANPAY) {
            # Only the current input is signed, not all inputs
            $data .= serialize_input_for_sign($self->in->[$input_num]);
        }
        else {
            $data .= varint(scalar @{$self->in});
            $data .= serialize_input_for_sign($_) foreach @{$self->in};
        }
        $sighash_type &= ~SIGHASH_ANYONECANPAY;
        if ($sighash_type == SIGHASH_ALL) {
            $data .= varint(scalar @{$self->out});
            $data .= serialize_output($_) foreach @{$self->out};
        }
        elsif ($sighash_type == SIGHASH_SINGLE) {
            # We do not need to sign coinbase transactions
            $data .= defined($self->out->[$input_num]) ? serialize_output($self->out->[$input_num]) : "";
        }
        elsif ($sighash_type != SIGHASH_NONE) {
            die "Unsupported sighash type $sighash_type";
        }
        # We do not need to sign coinbase transactions
        $self->{sign_data}->[$sighash_type] = $data;
    }
    if ($self->is_stake) {
        # It's stake tx which signs block, add block info
        $data .= $self->block_sign_data;
    }
    return $data;
}

sub type_as_text {
    my $self = shift;
    return TX_TYPES_NAMES->[$self->tx_type];
}

# For JSON RPC output
sub as_hashref {
    my $self = shift;
    my $res = {
        size => $self->size //= length($self->serialize),
        in   => $self->in_raw ? [ map { inputraw_as_hashref($_) } @{$self->in_raw} ] : [ map { input_as_hashref($_) } @{$self->in} ],
        out  => [ map { $self->output_as_hashref($_) } @{$self->out} ],
        type => $self->type_as_text,
    };
    $res->{hash} = $res->{txid} = unpack("H*", $self->hash) if defined $self->hash;
    $res->{fee} = $self->fee / DENOMINATOR if defined $self->fee;
    $res->{up} = $self->up->as_hashref if $self->up;
    $res->{coins_created} = $self->coins_created / DENOMINATOR if !UPGRADE_POW && defined $self->coins_created;
    $res->{time} = $self->received_time if defined $self->received_time;
    $res->{token_id} = unpack("H*", $self->token_hash) if $self->is_tokens && defined $self->token_hash;
    return $res;
}

sub input_as_hashref {
    my $in = shift;
    $in->{siglist} or die "Undefined siglist during input_as_hashref";
    return {
        txid          => unpack("H*", $in->{txo}->tx_in),
        num           => $in->{txo}->num+0,
        siglist       => [ map { unpack("H*", $_) } @{$in->{siglist}} ],
        redeem_script => unpack("H*", $in->{txo}->redeem_script // die "Undefined redeem_script during input_as_hashref"),
    };
}

sub inputraw_as_hashref {
    my $in = shift;
    $in->{siglist} or die "Undefined siglist during input_as_hashref";
    return {
        txid          => unpack("H*", $in->{tx_out}),
        num           => $in->{num}+0,
        siglist       => [ map { unpack("H*", $_) } @{$in->{siglist} // []} ],
        redeem_script => unpack("H*", $in->{redeem_script} // ""),
    };
}

sub serialize_siglist {
    my $siglist = shift;
    return varint(scalar @$siglist) . join("", map { varstr($_) } @$siglist);
}

sub serialize_input_unsigned {
    my $in = shift;
    return $in->{txo}->tx_in . varint($in->{txo}->num) . serialize_siglist($in->{siglist} // []) . varstr($in->{txo}->redeem_script // "");
}

sub serialize_input_raw {
    my $in = shift;
    return $in->{tx_out} . varint($in->{num}) . serialize_siglist($in->{siglist} // []) . varstr($in->{redeem_script} // "");
}

sub serialize_input {
    my $in = shift;
    my $siglist = $in->{siglist} // die "Undefined siglist during serialize_input";
    my $redeem_script = $in->{txo}->redeem_script // die "Undefined redeem_script during serialize_input";
    return $in->{txo}->tx_in . varint($in->{txo}->num) . serialize_siglist($siglist) . varstr($redeem_script);
}

sub serialize_input_for_sign {
    my $in = shift;
    return $in->{txo}->tx_in . varint($in->{txo}->num);
}

sub deserialize_siglist {
    my $data = shift;
    my $num = $data->get_varint() // return undef;
    my @siglist = map { $data->get_string() // return undef } 1 .. $num;
    return \@siglist;
}

sub deserialize_input {
    my $data = shift;
    return {
        tx_out        => ( $data->get(32) // return undef ),
        num           => ( $data->get_varint() // return undef ),
        siglist       => ( deserialize_siglist($data) // return undef ),
        redeem_script => ( $data->get_string() // return undef ),
    };
}

sub serialize_output {
    my $out = shift;
    return pack("Q<", $out->value) . varstr($out->scripthash) . varstr($out->data);
}

sub deserialize_output {
    my $data = shift;
    return {
        value      => unpack("Q<", $data->get(8) // return undef),
        scripthash => ( $data->get_string() // return undef ),
        data       => ( $data->get_string() // return undef ),
    };
}

sub output_as_hashref {
    my $self = shift;
    my $out = shift;
    my $res = {
        value   => $out->value / DENOMINATOR,
        address => $out->address,
        data    => unpack("H*", $out->data),
    };
    if ($self->is_tokens) {
        $res->{token_id} = unpack("H*", $self->token_hash || $self->hash);
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
            }
        }
    }
    return $res;
}

sub serialize_coinbase {
    my $coinbase = shift;
    return $coinbase->serialize;
}

sub deserialize_coinbase {
    my ($data, $upgrade_level) = @_;
    return QBitcoin::Coinbase->deserialize($data, $upgrade_level);
}

sub deserialize {
    my $class = shift;
    my ($data) = @_;
    my $start_index = $data->index;
    my $tx_type = unpack("c", $data->get(1));
    my $token_hash;
    $token_hash = $data->get_string() if $tx_type == TX_TYPE_TOKENS;
    my @input  = map { deserialize_input($data)  // return undef } 1 .. ($data->get_varint // return undef);
    my @output = map { deserialize_output($data) // return undef } 1 .. ($data->get_varint // return undef);
    my $up;
    my $upgrade_level;
    if ($tx_type == TX_TYPE_COINBASE) {
        if (UPGRADE_POW) {
            $upgrade_level = $data->get_varint;
            $upgrade_level < level_by_total(MAX_VALUE)
                or return undef;
            $up = deserialize_coinbase($data, $upgrade_level) // return undef;
        }
        else {
            $up = unpack("Q<", $data->get(8) // return undef);
        }
    }
    my $end_index = $data->index;
    $data->index = $start_index;
    my $tx_raw_data = $data->get($end_index - $start_index);
    my $hash = tx_data_hash($tx_raw_data);

    if ($end_index - $start_index > MAX_TX_SIZE) {
        Warningf("Transaction size %u exceeds maximum %u", $end_index - $start_index, MAX_TX_SIZE);
        return undef;
    }

    my $self = $class->new(
        in_raw        => \@input,
        out           => create_outputs(\@output, $hash, $tx_type == TX_TYPE_TOKENS ? $token_hash || $hash : undef),
        $up ? UPGRADE_POW ? ( up => $up, upgrade_level => $upgrade_level ) : ( coins_created => $up ) : (),
        tx_type       => $tx_type,
        $tx_type == TX_TYPE_TOKENS ? ( token_hash => $token_hash ) : (),
        hash          => $hash,
        size          => $end_index - $start_index,
        received_time => time(),
    );
    return $self;
}

sub is_pending {
    my $self = shift;
    return exists $PENDING_TX_INPUT{$self->hash};
}

sub has_pending {
    my $class = shift;
    my ($hash) = @_;
    return exists $PENDING_TX_INPUT{$hash};
}

sub load_txo {
    my $self = shift;

    $self->load_inputs
        or return undef; # transaction has no such output or incorrect redeem script
    $_->save foreach @{$self->out};

    if ($self->input_pending || $self->input_detached) {
        # put the transaction into separate "waiting" pull (limited size) and reprocess it by each received transaction
        foreach my $tx_in (keys %{$self->input_pending // {}}) {
            Debugf("Save transaction %s as pending for %s", $self->hash_str, $self->hash_str($tx_in));
            # request pending inputs
            if (!$PENDING_INPUT_TX{$tx_in}) {
                $self->received_from->request_tx($tx_in) if $self->received_from && $self->received_from->can('request_tx');
            }
            $PENDING_INPUT_TX{$tx_in}->{$self->hash} = $self;
        }
        foreach my $tx_in (keys %{$self->input_detached // {}}) {
            Debugf("Save transaction %s dependent on pending %s", $self->hash_str, $self->hash_str($tx_in));
            $PENDING_INPUT_TX{$tx_in}->{$self->hash} = $self;
        }
        $PENDING_TX_INPUT{$self->hash} = $self;
        foreach my $in (map { @$_ } values %{$self->input_detached // {}}) {
            $in->{txo}->spent_add($self);
        }
        $self->drop_immune = 1;
        if (keys %PENDING_TX_INPUT > MAX_PENDING_TX) {
            foreach my $pending_tx_hash (keys %PENDING_TX_INPUT) {
                my $pending_tx = $PENDING_TX_INPUT{$pending_tx_hash}
                    or next; # already dropped as dependent in this loop
                if ($pending_tx->drop()) {
                    Debugf("Drop old pending transaction %s", $pending_tx->hash_str);
                    last if keys %PENDING_TX_INPUT <= MAX_PENDING_TX;
                }
            }
        }
        delete $self->{drop_immune};
    }
    else {
        $self->calculate_fee();
    }

    foreach my $in (@{$self->in}) {
        $in->{txo}->spent_add($self);
    }

    return $self;
}

sub calculate_fee {
    my $self = shift;

    $self->fee = sum0(map { $_->{txo}->value } @{$self->in}) + $self->coins_created - sum0(map { $_->value } @{$self->out});
}

sub coins_created {
    my $self = shift;

    if (UPGRADE_POW) {
        return $self->up ? $self->up_value : 0;
    }
    else {
        return $self->{coins_created} // 0;
    }
}

sub create_outputs {
    my ($outputs, $hash, $token_hash) = @_;
    my @txo;
    my $num = 0;
    foreach my $out (@$outputs) {
        my $txo = QBitcoin::TXO->new_txo({
            value      => $out->{value},
            scripthash => $out->{scripthash},
            data       => $out->{data},
            tx_in      => $hash,
            num        => $num++,
            $token_hash ? ( token_hash => $token_hash ) : (),
        });
        push @txo, $txo;
    }
    return \@txo;
}

# get inputs as hashes from $self->in_raw
# and save them to $self->in and $self->input_pending
# request input_pending from remote ($self->received_from)
sub load_inputs {
    my $self = shift;
    my ($unsigned) = @_;

    my @loaded_inputs;
    my @need_load_txo;
    my %unknown_inputs;
    my %pending_inputs;
    my $inputs = delete $self->{in_raw};
    foreach my $in (@$inputs) {
        if (my $txo = QBitcoin::TXO->get($in)) {
            unless (($unsigned && $in->{redeem_script} eq "") || $txo->set_redeem_script($in->{redeem_script}) == 0) {
                Warningf("Incorrect redeem_script for input %s on %s", $txo->tx_in_str, $self->hash_str);
                return undef;
            }
            if (exists $PENDING_TX_INPUT{$in->{tx_out}}) {
                Infof("input %s:%u is pending in transaction %s",
                    $self->hash_str($in->{tx_out}), $in->{num}, $self->hash_str);
                $pending_inputs{$in->{tx_out}} //= [];
                push @{$pending_inputs{$in->{tx_out}}}, {
                    txo     => $txo,
                    siglist => $in->{siglist},
                };
            }
            else {
                push @loaded_inputs, {
                    txo     => $txo,
                    siglist => $in->{siglist},
                };
            }
        }
        else {
            push @need_load_txo, $in;
        }
    }

    if (@need_load_txo) {
        # var @txo here needed to prevent free txo objects as unused just after load
        my @txo = $self->is_tokens ? QBitcoin::TXO->load_tokens(@need_load_txo) : QBitcoin::TXO->load(@need_load_txo);
        my $class = ref $self;
        foreach my $in (@need_load_txo) {
            if (my $txo = QBitcoin::TXO->get($in)) {
                unless (($unsigned && $in->{redeem_script} eq "") || $txo->set_redeem_script($in->{redeem_script}) == 0) {
                    Warningf("Incorrect redeem_script for input %s on %s", $txo->tx_in_str, $self->hash_str);
                    return undef;
                }
                if (exists $PENDING_TX_INPUT{$in->{tx_out}}) {
                    Infof("input %s:%u is pending in transaction %s",
                        $self->hash_str($in->{tx_out}), $in->{num}, $self->hash_str);
                    $pending_inputs{$in->{tx_out}} //= [];
                    push @{$pending_inputs{$in->{tx_out}}}, {
                        txo     => $txo,
                        siglist => $in->{siglist},
                    };
                }
                else {
                    push @loaded_inputs, {
                        txo     => $txo,
                        siglist => $in->{siglist},
                    };
                }
            }
            else {
                if ($class->check_by_hash($in->{tx_out})) {
                    Warningf("Transaction %s has no output %u for tx %s input",
                        $self->hash_str($in->{tx_out}), $in->{num}, $self->hash_str);
                    return undef;
                }
                else {
                    Infof("input %s:%u not found in transaction %s",
                        $self->hash_str($in->{tx_out}), $in->{num}, $self->hash_str);
                    $unknown_inputs{$in->{tx_out}}->{$in->{num}} = $in;
                }
            }
        }
    }
    $self->in = [ sort { _cmp_inputs($a, $b) } @loaded_inputs ];
    $self->input_pending  = \%unknown_inputs if %unknown_inputs;
    $self->input_detached = \%pending_inputs if %pending_inputs;
    return $self;
}

sub _cmp_inputs {
    my ($in1, $in2) = @_;
    return $in1->{txo}->tx_in cmp $in2->{txo}->tx_in || $in1->{txo}->num <=> $in2->{txo}->num;
}

sub tx_data_hash {
    my ($tx_raw_data) = @_;
    return hash256($tx_raw_data);
}

sub calculate_hash {
    my $self = shift;
    my $tx_raw_data = $self->serialize;
    $self->size = length($tx_raw_data);
    $self->hash = tx_data_hash($tx_raw_data);
}

sub is_standard { $_[0]->{tx_type} == TX_TYPE_STANDARD }
sub is_stake    { $_[0]->{tx_type} == TX_TYPE_STAKE    }
sub is_coinbase { $_[0]->{tx_type} == TX_TYPE_COINBASE }
sub is_tokens   { $_[0]->{tx_type} == TX_TYPE_TOKENS   }

sub validate_coinbase {
    my $self = shift;
    # Each upgrade should correspond fixed and deterministic tx hash for qbitcoin
    if (@{$self->in}) {
        Warningf("Mixed input and coinbase in the transaction %s", $self->hash_str);
        return -1;
    }
    if (@{$self->out} != 1) {
        Warningf("Incorrect coinbase transaction %s: %u outputs, must be 1", $self->hash_str, scalar @{$self->out});
        return -1;
    }
    if ($self->out->[0]->data ne '') {
        Warningf("Incorrect transaction %s, coinbase can't contain data", $self->hash_str);
        return -1;
    }
    if (UPGRADE_POW) {
        if (!$self->up) {
            Warningf("Incorrect transaction %s, no coinbase information nor inputs", $self->hash_str);
            return -1;
        }
        $self->up->validate() == 0
            or return -1;
        if ($self->up->scripthash ne $self->out->[0]->scripthash) {
            Warningf("Mismatch scripthash for coinbase transaction %s", $self->hash_str);
            return -1 unless $config->{fake_coinbase};
            $self->up->scripthash = $self->out->[0]->scripthash;
        }
        if ($self->out->[0]->value != coinbase_value($self->up_value)) {
            Warningf("Mismatch value for coinbase transaction %s", $self->hash_str);
            return -1;
        }
    }
    else {
        Warningf("Coinbase denied, invalid transaction %s", $self->hash_str);
        return -1 unless $config->{fake_coinbase};
    }
    return 0;
}

sub validate_hash {
    my $self = shift;

    my $hash = $self->hash;
    $self->calculate_hash;
    if ($self->hash ne $hash) {
        Warningf("Incorrect serialized transaction has different hash: %s != %s", $self->hash_str, $self->hash_str($hash));
        return -1;
    }
    return 0;
}

sub validate {
    my $self = shift;

    if ($self->is_coinbase) {
        return $self->validate_coinbase;
    }
    # Transaction must contains at least one output (can't spend all inputs as fee)
    if (!@{$self->out}) {
        Warningf("No outputs in transaction %s", $self->hash_str);
        return -1;
    }
    # Transaction must contains at least one input
    if (!@{$self->in} && !$self->is_coinbase && !$self->is_stake) {
        Warningf("No inputs in transaction %s", $self->hash_str);
        return -1;
    }
    foreach my $out (@{$self->out}) {
        if ($out->value < 0 || $out->value > MAX_VALUE) {
            Warningf("Incorrect output value %ld in transaction %s", $out->value, $self->hash_str);
            return -1;
        }
        if (length($out->data) > MAX_TXO_DATA_SIZE) {
            Warningf("Too large output data size %u in transaction %s", length($out->data), $self->hash_str);
            return -1;
        };
        if (length($out->scripthash) > 32) {
            Warningf("Incorrect scripthash size %u in transaction %s", length($out->scripthash), $self->hash_str);
            return -1;
        }
    }
    my $class = ref $self;
    my $input_value = 0;
    my %inputs;
    foreach my $in (@{$self->in}) {
        my $txo = $in->{txo};
        if ($inputs{$txo->key}++) {
            Warningf("Input %s:%u included in transaction %s twice",
                $txo->tx_in_str, $txo->num, $self->hash_str);
            return -1;
        }
        if (length($txo->redeem_script) > MAX_REDEEM_SCRIPT_SIZE) {
            Warningf("Too large redeem script size %u in transaction %s input %s:%u",
                length($txo->redeem_script), $self->hash_str, $txo->tx_in_str, $txo->num);
            return -1;
        }
        if (length(serialize_siglist($in->{siglist} // [])) > MAX_SIGLIST_SIZE) {
            Warningf("Too large siglist size in transaction %s input %s:%u",
                $self->hash_str, $txo->tx_in_str, $txo->num);
            return -1;
        }
        $input_value += $txo->value;
    }
    if ($self->is_stake) {
        if ($self->fee >= 0) {
            Warningf("Fee for stake transaction %s is %li, not negative",
                $self->hash_str, $self->fee);
            return -1;
        }
    }
    elsif ($self->is_standard || $self->is_tokens) {
        if ($self->fee < 0) {
            Warningf("Fee for standard transaction %s is %li, can't be negative",
                $self->hash_str, $self->fee);
            return -1;
        }
        if ($self->fee == 0 && $self->size > MAX_EMPTY_TX_SIZE) {
            Warningf("Transaction %s with zero fee has too large size %u, fee must be at least 1 satoshi if size > %u bytes",
                $self->hash_str, $self->size, MAX_EMPTY_TX_SIZE);
            return -1;
        }
        # Signcheck for stake transaction depends on block it relates to,
        # so skip this check while block_sign_data is not known, check from valid_for_block()
        $self->check_input_script == 0
            or return -1;
        # Is this a token transaction?
        if ($self->is_tokens) {
            $self->check_tokens_tx() == 0
                or return -1;
        }
    }
    else {
        Warningf("Unknown type %d for transaction %s", $self->tx_type, $self->hash_str);
        return -1;
    }
    return 0;
}

sub unpack_token_info {
    my ($self, $data) = @_;
    my %res;
    my $last_attr = 1;
    for (my $i = 0; $i < length($data);) {
        my $type = substr($data, $i, 1);
        if (unpack("C", $type) <= $last_attr) {
            Watningf("Incorrect token attribute order in transaction %s token %s", $self->hash_str, $self->token_hash_str);
            return undef;
        }
        $last_attr = $type;
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
    my $token_tx = QBitcoin::Transaction->get_by_hash($self->token_hash)
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
                if ($data->{permissions} && ($data->{permissions} & !$permissions)) {
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

sub valid_for_block {
    my $self = shift;
    my ($block) = @_;
    if ($self->is_stake) {
        $self->block_sign_data = $block->sign_data;
        $self->check_input_script == 0
            or return -1;
    }
    ( $self->min_tx_time // "Inf" ) <= timeslot($block->time)
        or return -1;
    ( $self->min_tx_block_height // "Inf" ) <= $block->height
        or return -1;
    return 0;
}

sub check_input_script {
    my $self = shift;
    $self->{min_tx_time} = -1;
    $self->{min_tx_block_height} = -1;
    foreach my $num (0 .. $#{$self->in}) {
        my $in = $self->in->[$num];
        if ($in->{txo}->check_script($in->{siglist}, $self, $num) != 0) {
            Warningf("Unmatched check script for input %s:%u in transaction %s",
                $in->{txo}->tx_in_str, $in->{txo}->num, $self->hash_str);
            return -1;
        }
        # Set txo min_rel_time to STAKE_MATURITY if previous tx is stake
        if (($self->is_standard || $self->is_tokens) && ($in->{min_rel_time} // -1) < STAKE_MATURITY) {
            my $tx_in_type = (ref $self)->type_by_hash($in->{txo}->tx_in);
            if (!defined($tx_in_type)) {
                Errf("No input transaction %s for txo", $in->{txo}->tx_in_str);
                return -1;
            }
            if ($tx_in_type == TX_TYPE_STAKE) {
                $in->{min_rel_time} = STAKE_MATURITY;
            }
        }
    }
    return 0;
}

sub type_by_hash {
    my $class = shift;
    my ($hash) = @_;

    if (my $tx = $class->get($hash)) {
        return $tx->tx_type;
    }
    elsif (my ($tx_hashref) = $class->fetch(hash => $hash)) {
        return $tx_hashref->{tx_type};
    }
    else {
        return undef;
    }
}

sub announce {
    my $self = shift;
    my $recv_peer = $self->received_from_peer ? $self->received_from->peer : undef;
    foreach my $connection (QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN)) {
        next if $recv_peer && $connection->peer->id eq $recv_peer->id;
        next unless $connection->protocol->can("announce_tx");
        $connection->protocol->announce_tx($self);
    }
}

sub pre_load {
    my $class = shift;
    my ($attr) = @_;
    if (!$TRANSACTION{$attr->{hash}}) {
        # Load TXO for inputs and outputs
        my @outputs = QBitcoin::TXO->load_stored_outputs($attr->{id}, $attr->{hash});
        $attr->{out} = \@outputs;
        if ($attr->{tx_type} == TX_TYPE_COINBASE) {
            if (UPGRADE_POW) {
                my $upgrade = QBitcoin::Coinbase->load_stored_coinbase($attr->{id}, $attr->{hash});
                if ($upgrade) {
                    $attr->{up} = $upgrade;
                    $attr->{upgrade_level} = $upgrade->upgrade_level;
                    $attr->{up_value} = $upgrade->value;
                }
                else {
                    Errf("No coinbase for transaction %s", lc unpack("H*", substr($attr->{hash}, 0, 4)));
                }
            }
            else {
                $attr->{coins_created} = sum0(map { $_->value } @outputs) + $attr->{fee};
            }
            $attr->{in} = [];
        }
        else {
            my @in_txo = $attr->{tx_type} == TX_TYPE_TOKENS
                ? QBitcoin::TXO->load_stored_token_inputs($attr->{id}, $attr->{hash})
                : QBitcoin::TXO->load_stored_inputs($attr->{id}, $attr->{hash});
            my @inputs;
            foreach my $txo (@in_txo) {
                push @inputs, {
                    txo     => $txo,
                    siglist => $txo->siglist,
                };
            }
            $attr->{in} = \@inputs;
        }
        if ($attr->{tx_type} == TX_TYPE_TOKENS) {
            my $token_hash;
            if ($attr->{token_id} ) {
                my ($token_tx) = QBitcoin::Transaction->fetch(id => $attr->{token_id});
                if (!$token_tx) {
                    Errf("No token transaction id %u for transaction %s", $attr->{token_id}, unpack("H*", $attr->{hash}));
                    die "No token transaction id $attr->{token_id} for transaction " . unpack("H*", $attr->{hash}) . "\n";
                }
                $token_hash = $token_tx->{hash};
                $attr->{token_hash} = $token_tx->{hash};
            }
            else {
                $token_hash = $attr->{hash};
            }
            foreach my $out (@{$attr->{out}}) {
                $out->token_hash = $token_hash;
            }
        }
    }
    return $attr;
}

sub new {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    # tx inputs are not sorted in the database, so sort them here for get deterministic transaction hash
    $attr->{in} = [ sort { _cmp_inputs($a, $b) } @{$attr->{in}} ];
    my $self = bless $attr, $class;
    return $self;
}

sub on_load {
    my $self = shift;

    my $hash = $self->hash;
    if ($TRANSACTION{$hash}) {
        $self = $TRANSACTION{$hash};
    }
    else {
        $self->calculate_hash;
        if ($self->hash ne $hash) {
            Errf("Incorrect hash for loaded transaction %s != %s", $self->hash_str, $self->hash_str($hash));
            Errf("Serialized transaction in hex: %s", unpack("H*", $self->serialize));
            die "Incorrect hash for loaded transaction " . $self->hash_str . " != " . $self->hash_str($hash) . "\n";
        }
    }

    return $self;
}

sub confirm {
    my $self = shift;
    my ($block, $pos) = @_;

    $self->block_height = $block->height;
    $self->block_pos = $pos;
    $self->block_time = $block->time;
    if (my $coinbase = $self->up) {
        $coinbase->tx_out = $self->hash;
        $coinbase->upgrade_level = $self->upgrade_level;
        $coinbase->value = $self->up_value;
    }
    foreach my $in (@{$self->in}) {
        my $txo = $in->{txo};
        $txo->tx_out = $self->hash;
        $txo->siglist = $in->{siglist};
        $txo->del_my_utxo if $txo->is_my; # for stake transaction
    }
    foreach my $txo (@{$self->out}) {
        $txo->add_my_utxo if $txo->is_my && $txo->unspent;
    }
    # min proper block_height and time should be recalculated for depended transactions
    if (exists $TX_SEQ_DEPENDS{$self->hash}) {
        foreach my $tx (values %{$TX_SEQ_DEPENDS{$self->hash}}) {
            delete $tx->{min_tx_rel_time};
            delete $tx->{min_tx_rel_block_height};
        }
    }
}

sub unconfirm {
    my $self = shift;
    Debugf("unconfirm transaction %s (confirmed in block height %u)", $self->hash_str, $self->block_height);
    $self->is_cached or die "unconfirm not cached transaction " . $self->hash_str;
    $self->block_height = undef;
    $self->block_time = undef;
    $self->block_pos = undef;
    foreach my $in (@{$self->in}) {
        my $txo = $in->{txo};
        $txo->tx_out = undef;
        $txo->siglist = undef;
        # TXO will be returned to list of my utxo later, on drop the branch and free the block
    }
    foreach my $txo (@{$self->out}) {
        $txo->del_my_utxo() if $txo->is_my;
    }
    if ($self->id) {
        # Transaction will be deleted by "foreign key (block_height) references block (height) on delete cascade" on replace block
        # $self->delete;
        $self->id = undef;
    }
    if (my $coinbase = $self->up) {
        $coinbase->tx_out = undef;
    }
    # dependent transactions with seq limits should not be confirmed
    if (exists $TX_SEQ_DEPENDS{$self->hash}) {
        foreach my $tx (values %{$TX_SEQ_DEPENDS{$self->hash}}) {
            $tx->{min_tx_rel_time} = undef if exists $tx->{min_tx_rel_time};
            $tx->{min_tx_rel_block_height} = undef if exists $tx->{min_tx_rel_block_height};
        }
    }
}

sub is_cached {
    my $self = shift;

    return exists($TRANSACTION{$self->hash}) && refaddr($TRANSACTION{$self->hash}) == refaddr($self);
}

sub txo_height {
    my $class = shift;
    my ($txo) = @_;
    my $block_time;
    my $block_height;
    if (my $tx_in = $class->get($txo->tx_in)) {
        # block_time may be differ from the time of the best block with block_height if we're checking alternative branch
        $block_time = $tx_in->block_time;
        if (!defined($block_height = $tx_in->block_height)) {
            return undef;
        }
    }
    elsif (my ($tx_hashref) = $class->fetch(hash => $txo->tx_in)) {
        $block_height = $tx_hashref->{block_height};
    }
    else {
        # tx generated this txo should be loaded during tx validation
        Errf("No input transaction %s for txo", $txo->tx_in_str);
        return undef;
    }
    return wantarray ? ($block_height, $block_time) : $block_height;
}

sub txo_time {
    my $class = shift;
    my ($txo) = @_;

    my ($block_height, $block_time) = $class->txo_height($txo);
    if (!$block_time) {
        defined($block_height) or return undef;
        # The transaction was loaded from the database, so we can get block time from the blockchain
        my $block = QBitcoin::Block->best_block($block_height) // QBitcoin::Block->find(height => $block_height)
            or die "Can't find block height $block_height\n";
        $block_time = $block->time;
    }
    return $block_time;
}

sub stake_weight {
    my $self = shift;
    my ($block) = @_;
    my $weight = 0;
    if ($self->is_stake) {
        my $class = ref $self;
        foreach my $in (map { $_->{txo} } @{$self->in}) {
            my $in_block_time = $class->txo_time($in);
            if (!defined($in_block_time)) {
                Warningf("Can't get stake_weight for %s with unconfirmed input %s:%u",
                    $self->hash_str, $in->tx_in_str, $in->num);
                next;
            }
            # TODO: Use Math::BigInt to prevent int64 overflow
            $weight += $in->value * (timeslot($block->time) - timeslot($in_block_time)) / BLOCK_INTERVAL;
        }
    }
    return int($weight / 0x10000); # prevent int64 overflow for total blockchain weight
}

sub coinbase_weight {
    my $self = shift;
    my ($block_time) = @_;
    my $weight = 0;
    if (my $coinbase = $self->up) {
        # Early confirmation should have more weight than later
        my $base_time = timeslot($coinbase->btc_confirm_time);
        my $virtual_time = timeslot($coinbase->btc_confirm_time - COINBASE_WEIGHT_TIME); # MB negative, it's ok
        $weight = $self->up_value * ($base_time - $virtual_time) / BLOCK_INTERVAL;
        $weight *= ($base_time - $virtual_time) / (timeslot($block_time) - $virtual_time);
    }
    return int($weight / 0x10000); # prevent int64 overflow for total blockchain weight
}

sub up_value {
    my $self = shift;
    return $self->{up_value} //= $self->up->get_value($self->upgrade_level);
}

sub coinbase_value {
    my ($value) = @_;
    return int($value * (1 - UPGRADE_FEE));
}

# Create a transaction with already exising coinbase output
sub new_coinbase {
    my $class = shift;
    my ($coinbase, $upgrade_level) = @_;

    my $value = $coinbase->get_value($upgrade_level);
    my $txo = QBitcoin::TXO->new_txo({
        value      => coinbase_value($value),
        scripthash => $coinbase->scripthash,
    });
    my $self = $class->new(
        in            => [],
        out           => [ $txo ],
        up            => $coinbase,
        tx_type       => TX_TYPE_COINBASE,
        fee           => $value - $txo->value,
        received_time => time(),
        upgrade_level => $upgrade_level,
    );
    $self->calculate_hash;
    if (my $cached = $class->get($self->hash)) {
        Debugf("Coinbase transaction %s for btc %s:%u already in %s",
            $self->hash_str, $class->hash_str($coinbase->btc_tx_hash), $coinbase->btc_out_num,
            $cached->block_height ? "blockchain" : "mempool");
        $self = $cached;
    }
    else {
        QBitcoin::TXO->save_all($self->hash, $self->out);
        $self->save(); # Add coinbase tx to mempool
        Infof("Generated new coinbase transaction %s for btc output %s:%u value %lu fee %lu",
            $self->hash_str, $class->hash_str($coinbase->btc_tx_hash), $coinbase->btc_out_num,
            $txo->value, $self->fee);
        $self->announce();
    }
    return $self;
}

# $self->{min_tx_time}, $self->{min_tx_block_height}: minimal time and block_height for transaction set by checklocktimeverify opcode
# Set to -1 if unlimited (default), undef if unknown (loaded from database, need to check)
# $self->{min_tx_rel_time}, $self->{min_tx_rel_block_height}: minimal time and block_height for transaction
# These set by both checklocktimeverify and checksequenceverify opcode to minimum block height and time of all inputs
# Methods min_tx_time and min_tx_block_height cache calculated values to $self->{min_tx_rel_time} and $self->{min_tx_rel_block_height} keys
# Set these values to undef means that dependent transaction is not confirmed, so the transaction should not be confirmed too
# Delete these values means these values are unknown and should be recalculated in input scripts

# For standard transaction this can be set by check_input_script() if it execute "checklocktimeverify" opcode
sub set_min_tx_time {
    my $self = shift;
    my ($val) = @_;

    if (defined($self->{min_tx_time}) && $self->{min_tx_time} < $val) {
        $self->{min_tx_time} = $val;
    }
}

sub min_tx_time {
    my $self = shift;

    if ($self->up) {
        return $self->up->min_tx_time;
    }
    if (exists $self->{min_tx_rel_time}) {
        return $self->{min_tx_rel_time};
    }
    if (!exists $self->{min_tx_time}) {
        # min_tx_time may be unknown if the transaction was loaded from database
        # and then unconfirmed (moved to mempool)
        $self->check_input_script;
    }
    my $min_tx_time = $self->{min_tx_time};
    foreach my $in (@{$self->in}) {
        my $min_rel_time = $in->{min_rel_time}
            or next;
        my $txo = $in->{txo};
        # reset $self->{min_tx_rel_time} if previous tx confirmed or unconfirmed
        $TX_SEQ_DEPENDS{$txo->tx_in}->{$self->hash} = $self if $self->is_cached;
        my $txo_time = QBitcoin::Transaction->txo_time($txo);
        if (defined($txo_time)) {
            $min_tx_time = $min_rel_time + $txo_time if defined($min_tx_time) && $min_tx_time < $min_rel_time + $txo_time;
        }
        else {
            $min_tx_time = undef;
        }
    }
    return $self->{min_tx_rel_time} = $min_tx_time;
}

sub set_min_tx_block_height {
    my $self = shift;
    my ($val) = @_;

    if (defined($self->{min_tx_block_height}) && $self->{min_tx_block_height} < $val) {
        $self->{min_tx_block_height} = $val;
    }
}

sub min_tx_block_height {
    my $self = shift;

    if ($self->up) {
        return -1;
    }
    if (exists $self->{min_tx_rel_block_height}) {
        return $self->{min_tx_rel_block_height};
    }
    if (!exists $self->{min_tx_block_height}) {
        # min_tx_block_height may be unknown if the transaction was loaded from database
        # and then unconfirmed (moved to mempool)
        $self->check_input_script;
    }
    my $min_tx_height = $self->{min_tx_block_height};
    foreach my $in (@{$self->in}) {
        my $min_rel_height = $in->{min_rel_block_height}
            or next;
        my $txo = $in->{txo};
        $TX_SEQ_DEPENDS{$txo->tx_in}->{$self->hash} = $self; # reset $self->{min_tx_rel_block_height} if previous tx confirmed or unconfirmed
        my $txo_height = QBitcoin::Transaction->txo_height($txo);
        if (defined($txo_height)) {
            $min_tx_height = $min_rel_height + $txo_height if defined($min_tx_height) && $min_tx_height < $min_rel_height + $txo_height;
        }
        else {
            $min_tx_height = undef;
        }
    }
    return $self->{min_tx_rel_block_height} = $min_tx_height;
}

sub drop_all_pending {
    my $class = shift;
    my ($connection) = @_;

    foreach my $tx_hash (keys %PENDING_TX_INPUT) {
        my $tx = $PENDING_TX_INPUT{$tx_hash}
            or next;
        if ($tx->received_from_peer && $tx->received_from->peer->id eq $connection->peer->id) {
            $tx->drop();
        }
    }
}

1;
