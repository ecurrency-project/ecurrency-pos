package QBitcoin::REST;
use warnings;
use strict;

# Esplora RESTful HTTP API
# https://github.com/blockstream/esplora/blob/master/API.md

use JSON::XS;
use Time::HiRes;
use List::Util qw(sum0);
use HTTP::Headers;
use HTTP::Response;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::ORM qw(dbh);
use QBitcoin::Address qw(address_by_hash);
use QBitcoin::Transaction;
use QBitcoin::Block;
use QBitcoin::Utils qw(get_address_txo);
use parent qw(QBitcoin::HTTP);

use constant {
    FALSE => JSON::XS::false,
    TRUE  => JSON::XS::true,
};

use constant DEBUG_REST => 0;

my $JSON = JSON::XS->new;

sub type_id() { PROTOCOL_REST }

sub timeout {
    my $self = shift;
    my $time = shift // time();
    my $timeout = REST_TIMEOUT + $self->update_time - $time;
    if ($timeout < 0) {
        Infof("REST client timeout");
        $self->connection->disconnect;
        $timeout = 0;
    }
    return $timeout;
}

sub process_request {
    my $self = shift;
    my ($http_request) = @_;

    my @path = $http_request->uri->path_segments
        or return $self->http_response(404, "Unknown request");
    shift @path if @path && $path[0] eq "";
    shift @path if @path && $path[0] eq "api";
    return $self->http_response(404, "Unknown request") unless @path;
    DEBUG_REST && Debugf("REST request: /%s", join("/", @path));
    if ($path[0] eq "tx") {
        if ($http_request->method eq "POST") {
            @path == 1 or return $self->http_response(404, "Unknown request");
            return $self->tx_send($http_request->decoded_content);
        }
        ($path[1] && $path[1] =~ qr/^[0-9a-f]{64}\z/)
            or return $self->http_response(404, "Unknown request");
        my $tx = QBitcoin::Transaction->get_by_hash(pack("H*", $path[1]))
            or return $self->http_response(404, "Transaction not found");
        if (@path == 2) {
            return $self->http_ok(tx_obj($tx));
        }
        if (@path == 3) {
            if ($path[2] eq "status") {
                return $self->http_ok(tx_status($tx));
            }
            elsif ($path[2] eq "hex") {
                return $self->http_ok(unpack("H*", $tx->serialize));
            }
            elsif ($path[2] eq "raw") {
                return $self->http_ok($tx->serialize);
            }
            elsif ($path[2] eq "outspends") {
                my @out;
                foreach my $out (@{$tx->out}) {
                    push @out, {
                        spent => $out->tx_out ? TRUE : FALSE,
                        $out->tx_out ? (
                            txid => unpack("H*", $out->tx_out),
                        ) : (),
                    };
                }
                return $self->http_ok(\@out);
            }
            elsif ($path[2] eq "merkleblock-proof") {
                return $self->http_response(500, "Unimplemented");
            }
            elsif ($path[2] eq "merkle-proof") {
                $tx->block_height
                    or return $self->http_response(404, "Transaction unconfirmed");
                my $res = merkle_proof($tx);
                return $res ? $self->http_ok($res) : $self->http_response(500, "Something went wrong");
            }
            else {
                return $self->http_response(404, "Unknown request");
            }
        }
        elsif (@path == 4) {
            if ($path[2] eq "outspend" && $path[3] =~ /^(?:0|[1-9][0-9]*)\z/) {
                return $self->http_ok({
                    spent => $tx->out->[$path[3]]->tx_out ? TRUE : FALSE,
                    $tx->out->[$path[3]]->tx_out ? (
                        txid => unpack("H*", $tx->out->[$path[3]]->tx_out),
                    ) : (),
                });
            }
            else {
                return $self->http_response(404, "Unknown request");
            }
        }
        else {
            return $self->http_response(404, "Unknown request");
        }
    }
    elsif ($path[0] eq "address") {
        validate_address($path[1])
            or return $self->http_response(404, "Unknown request");
        if (@path == 2) {
            return $self->get_address_stats($path[1]);
        }
        elsif ($path[2] eq "txs") {
            return $self->get_address_txs($path[1], ($path[3] // "") eq "mempool" ? 0 : 25, ($path[3] // "") eq "chain" ? 0 : 50, $path[4]);
        }
        elsif ($path[2] eq "utxo") {
            @path == 3
                or return $self->http_response(404, "Unknown request");
            return $self->get_address_utxo($path[1]);
        }
    }
    elsif ($path[0] eq "address-prefix") {
        return $self->http_response(500, "Unimplemented");
    }
    elsif ($path[0] eq "block") {
        ($path[1] && $path[1] =~ qr/^[0-9a-f]{64}\z/)
            or return $self->http_response(404, "Unknown request");
        my $block = $self->get_block_by_hash(pack("H*", $path[1]))
            or return $self->http_response(404, "Block not found");
        if (@path == 2) {
            return $self->http_ok(block_obj($block));
        }
        if ($path[2] eq "txids") {
            @path == 3
                or return $self->http_response(404, "Unknown request");
            return $self->http_ok([ map { unpack("H*", $_->hash) } @{$block->tx_hashes} ]);
        }
        if ($path[2] eq "txs") {
            my $start_ndx = $path[3] || 0;
            my @ret;
            if ($start_ndx < @{$block->transactions} && $start_ndx >= 0) {
                my $end_ndx = $start_ndx + 24;
                $end_ndx = @{$block->transactions}-1 if $end_ndx >= @{$block->transactions};
                @ret = map { tx_obj($_) } @{$block->transactions}[$start_ndx .. $end_ndx];
            }
            return $self->http_ok(\@ret);
        }
        if ($path[2] eq "txid") {
            if ($path[3] >= @{$block->transactions} || $path[3] < 0) {
                return $self->http_response(404, "Transaction not found");
            }
            return $self->http_ok(tx_obj($block->transactions->[$path[3]]));
        }
        if ($path[2] eq "raw") {
            return $self->http_ok($block->serialize);
        }
        if ($path[2] eq "header") {
            return $self->http_ok(unpack("H*", $block->serialize));
        }
        if ($path[2] eq "status") {
            my $best_block = block_by_height($block->height);
            my $is_best = $best_block && $best_block->hash eq $block->hash;
            my $next_best;
            if ($is_best && $block->height < QBitcoin::Block->blockchain_height) {
                $next_best = block_by_height($block->height + 1);
            }
            return $self->http_ok({
                in_best_chain => $is_best ? TRUE : FALSE,
                height        => $block->height,
                $next_best ? ( next_best => unpack("H*", $next_best->hash) ) : (),
            });
        }
        return $self->http_response(404, "Unknown request");
    }
    elsif ($path[0] eq "blocks") {
        if (@path == 1 || @path == 2) {
            return $self->get_blocks($path[1]);
        }
        (@path == 3 && $path[1] eq "tip")
            or return $self->http_response(404, "Unknown request");
        my $best_height = QBitcoin::Block->blockchain_height;
        my $block = QBitcoin::Block->best_block($best_height)
            or return $self->http_response(500, "No blocks loaded");
        if ($path[2] eq "height") {
            return $self->http_ok($block->height);
        }
        elsif ($path[2] eq "hash") {
            return $self->http_ok(unpack("H*", $block->hash));
        }
        else {
            return $self->http_response(404, "Unknown request");
        }
    }
    elsif ($path[0] eq "block-height") {
        (@path == 2 && $path[1] =~ /^(?:0|[1-9][0-9]*)\z/)
            or return $self->http_response(404, "Unknown request");
        my $block = block_by_height($path[1])
            or return $self->http_response(404, "Block not found");
        return $self->http_ok(unpack("H*", $block->hash));
    }
    elsif ($path[0] eq "mempool") {
        my @mempool = QBitcoin::Transaction->mempool_list();
        if (@path == 1) {
            return $self->http_ok({
                count     => scalar(@mempool),
                vsize     => sum0(map { $_->size } @mempool),
                total_fee => sum0(map { $_->fee } @mempool),
                # fee_histogram => ???, # TODO
            });
        }
        @path == 2
            or return $self->http_response(404, "Unknown request");
        if ($path[1] eq "txids") {
            return $self->http_ok([ map { unpack("H*", $_->hash) } @mempool ]);
        }
        elsif ($path[1] eq "recent") {
            my @mempool = sort { ($b->received_time // 0) <=> ($a->received_time // 0) } @mempool;
            return $self->http_ok([ map { tx_obj($_) } grep { defined } @mempool[0..9] ]);
        }
        else {
            return $self->http_response(404, "Unknown request");
        }
    }
    elsif ($path[0] eq "fee-estimates") {
        return $self->http_ok({ 1 => 0 }); # TODO
    }
    elsif ($path[0] eq "asset") {
        return $self->http_response(500, "Unimplemented");
    }
    elsif ($path[0] eq "assets") {
        return $self->http_response(500, "Unimplemented");
    }
    else {
        return $self->http_response(404, "Unknown request");
    }
}

sub http_ok {
    my $self = shift;
    my ($response) = @_;
    my $body;
    my $cont_type;
    if (ref($response)) {
        $body = $JSON->encode($response);
        $cont_type = "application/json";
    }
    else {
        $body = $response;
        $cont_type = $body =~ /^[[:print:]]*$/ ? "text/plain" : "application/octet-stream";
    }
    my $headers = HTTP::Headers->new(
        Content_Type   => $cont_type,
        Content_Length => length($body),
    );
    my $http_response = HTTP::Response->new(200, "OK", $headers, $body);
    $http_response->protocol("HTTP/1.1");
    DEBUG_REST && Debugf("REST response: %s", $cont_type eq "application/octet-stream" ? "X'" . unpack("H*", $body) : $body);
    return $self->send($http_response->as_string("\r\n"));
}

sub http_response {
    my $self = shift;
    my ($code, $message, $body) = @_;
    $body //= "";
    my $headers = HTTP::Headers->new(
        Content_Type   => "text/plain",
        Content_Length => length($body),
    );
    my $response = HTTP::Response->new($code, $message, $headers, $body);
    $response->protocol("HTTP/1.1");
    return $self->send($response->as_string("\r\n"));
}

sub response_error {
    my $self = shift;
    my ($message, $code, $result) = @_;
    return $self->http_response(500, $message, $result);
}

sub validate_address {
    $_[0] =~ ($config->{testnet} ? ADDRESS_TESTNET_RE : ADDRESS_RE);
}

sub tx_status {
    my ($tx) = @_;
    if (defined $tx->block_height) {
        return {
            confirmed    => TRUE,
            block_height => $tx->block_height,
            # block_hash   => unpack("H*", $block->hash),
        };
    }
    else {
        return { confirmed => FALSE };
    }
}

sub block_by_height {
    my ($height) = @_;
    return QBitcoin::Block->best_block($height) // QBitcoin::Block->find(height => $height);
}

sub vin_obj {
    my ($vin) = @_;
    return {
        txid          => unpack("H*", $vin->{txo}->tx_in),
        vout          => $vin->{txo}->num,
        redeem_script => unpack("H*", $vin->{txo}->redeem_script),
        siglist       => [ map { unpack("H*", $_) } @{$vin->{siglist}} ],
        prevout       => {
            value              => $vin->{txo}->value,
            scripthash         => unpack("H*", $vin->{txo}->scripthash),
            scripthash_address => address_by_hash($vin->{txo}->scripthash),
        },
    };
}

sub tx_obj {
    my ($tx) = @_;
    my $block = defined($tx->block_height) ? block_by_height($tx->block_height) : undef;
    return {
        txid          => unpack("H*", $tx->hash),
        fee           => $tx->fee,
        size          => $tx->size,
        value         => sum0(map { $_->value } @{$tx->out}) + $tx->fee,
        is_coinbase   => $tx->is_coinbase ? TRUE : FALSE,
        received_time => $tx->received_time // undef,
        status        => {
            defined($tx->block_height) ? (
                block_height => $tx->block_height,
                block_pos    => $tx->block_pos,
                confirmed    => TRUE,
            ) : (
                confirmed => FALSE,
            ),
            defined($block) ? (
                block_time   => $block->time,
                block_hash   => unpack("H*", $block->hash),
            ) : (),
        },
        vin  => [ map { vin_obj($_) } @{$tx->in} ],
        vout => [ map {{ value => $_->value, scripthash => unpack("H*", $_->scripthash), scripthash_address => address_by_hash($_->scripthash) }} @{$tx->out} ],
    };
}

sub block_obj {
    my $block = shift;
    return {
        id                => unpack("H*", $block->hash),
        height            => $block->height,
        weight            => $block->weight,
        block_weight      => $block->self_weight,
        previousblockhash => $block->prev_hash ? unpack("H*", $block->prev_hash) : undef,
        merkle_root       => unpack("H*", $block->merkle_root),
        timestamp         => $block->time,
        tx_count          => scalar(@{$block->tx_hashes}),
        size              => length($block->serialize),
    };
}

sub txo_stats {
    my ($txo) = @_;
    # tx_count, funded_txo_count, funded_txo_sum, spent_txo_count and spent_txo_sum
    return {
        tx_count         => scalar(keys %$txo),
        funded_txo_count => scalar(grep { defined($_) } map { @$_ } values %$txo),
        funded_txo_sum   => sum0(map { $_->[0] } grep { defined($_) } map { @$_ } values %$txo),
        spent_txo_count  => scalar(grep { defined($_) && defined($_->[3]) } map { @$_ } values %$txo),
        spent_txo_sum    => sum0(map { $_->[0] } grep { defined($_) && defined($_->[3]) } map { @$_ } values %$txo),
    };
}

sub get_address_stats {
    my $self = shift;
    my ($address) = @_;
    my ($txo_chain, $txo_mempool) = get_address_txo($address)
        or return $self->http_response(404, "Incorrect address");
    return $self->http_ok({
        chain_stats   => txo_stats($txo_chain),
        mempool_stats => txo_stats($txo_mempool),
    });
}

sub get_address_txs {
    my $self = shift;
    my ($address, $chain_cnt, $mempool_cnt, $last_seen) = @_;
    my ($txo_chain, $txo_mempool) = get_address_txo($address)
        or return $self->http_response(404, "Incorrect address");
    my @tx;
    if ($mempool_cnt) {
        foreach my $txid (keys %$txo_mempool) {
            my $tx = QBitcoin::Transaction->get($txid)
                or next;
            push @tx, tx_obj($tx);
            last unless --$mempool_cnt;
        }
        @tx = sort { ($b->{received_time} // 0) <=> ($a->{received_time} // 0) } @tx;
    }
    if ($chain_cnt) {
        my $skip_until_tx;
        if ($last_seen && $last_seen =~ /^[0-9a-f]{64}\z/) {
            my $last_seen_bin = pack("H*", $last_seen);
            if ($txo_chain->{$last_seen_bin}) {
                $skip_until_tx = $last_seen_bin;
            }
        }
        foreach my $txid (sort { $txo_chain->{$b}->{height} <=> $txo_chain->{$a}->{height} || $txo_chain->{$b}->{block_pos} <=> $txo_chain->{$a}->{block_pos} } keys %$txo_chain) {
            if ($skip_until_tx) {
                $skip_until_tx = undef if $skip_until_tx eq $txid;
                next;
            }
            my $tx = QBitcoin::Transaction->get_by_hash($txid)
                or next;
            push @tx, tx_obj($tx);
            last unless --$chain_cnt;
        }
    }
    return $self->http_ok(\@tx);
}

sub get_address_utxo {
    my $self = shift;
    my ($address) = @_;
    my ($txo_chain, $txo_mempool) = get_address_txo($address)
        or return $self->http_response(404, "Incorrect address");
    my @utxo;
    foreach my $txid (keys %$txo_chain) {
        for (my $vout = 0; $vout < @{$txo_chain->{$txid}}; $vout++) {
            push @utxo, {
                txid      => $txid,
                vout      => $vout,
                value     => $txo_chain->{$txid}->[$vout]->[0],
                height    => $txo_chain->{$txid}->[$vout]->[1],
                block_pos => $txo_chain->{$txid}->[$vout]->[2],
                status    => "confirmed",
            } if $txo_chain->{$txid}->[$vout] && !defined($txo_chain->{$txid}->[$vout]->[3]);
        }
    }
    @utxo = sort { $a->{height} <=> $b->{height} || $a->{block_pos} <=> $b->{block_pos} } @utxo;
    foreach my $txid (keys %$txo_mempool) { # TODO: sort by received_time
        my @mempool_utxo;
        for (my $vout = 0; $vout < @{$txo_mempool->{$txid}}; $vout++) {
            push @mempool_utxo, {
                txid   => $txid,
                vout   => $vout,
                value  => $txo_mempool->{$txid}->[$vout]->[0],
                status => "unconfirmed",
            } if $txo_mempool->{$txid}->[$vout] && !defined($txo_mempool->{$txid}->[$vout]->[3]);
        }
    }
    return $self->http_ok(\@utxo);
}

sub merkle_proof {
    my ($tx) = @_;
    my $block = block_by_height($tx->block_height)
        or return undef;
    my $num = $tx->block_pos;
    if ($block->tx_hashes->[$num] ne $tx->hash) {
        Errf("block %s %u tx hash %s != %s", $block->hash_str, $num, $tx->hash_str($block->tx_hashes->[$num]), $tx->hash_str);
        return undef;
    }
    my $merkle_path = $block->merkle_path($num);
    my $hashlen = length($tx->hash);
    my $merkle_len = length($merkle_path) / $hashlen;
    my @merkle_path = map { unpack("H*", substr($merkle_path, $_*$hashlen, $hashlen)) } 1 .. $merkle_len;
    return {
        block_height => $block->height,
        pos          => $num,
        merkle       => \@merkle_path,
    };
}

sub get_blocks {
    my $self = shift;
    my ($height) = @_;
    my $best_height = QBitcoin::Block->blockchain_height;
    if (defined($height) && $height ne "" && $height ne "recent") {
        $height =~ /^(?:0|[1-9][0-9]*)\z/
            or return $self->http_response(404, "Incorrect request");
        $height <= $best_height
            or return $self->http_response(404, "Block not found");
    }
    else {
        $height = $best_height;
    }
    my @blocks;
    for (; $height >= 0 && @blocks < 10; $height--) {
        my $block = QBitcoin::Block->best_block($height)
            or last;
        push @blocks, block_obj($block);
    }
    if ($height >= 0 && @blocks < 10) {
        push @blocks, map { block_obj($_) }
            QBitcoin::Block->find(height => { '<=' => $height }, -sortby => "height DESC", -limit => 10-@blocks);
    }
    return $self->http_ok(\@blocks);
}

1;
