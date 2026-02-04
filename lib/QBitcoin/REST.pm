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
use QBitcoin::Utils qw(get_address_txs get_address_utxo address_stats all_tokens_balance get_tokens_txs);
use QBitcoin::ProtocolState qw(blockchain_synced btc_synced);
use QBitcoin::Coinbase;
use QBitcoin::ConnectionList;
use Bitcoin::Block;
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
            return $self->list_address_txs($path[1], ($path[3] // "") eq "mempool" ? 0 : 25, ($path[3] // "") eq "chain" ? 0 : 50, $path[4]);
        }
        elsif ($path[2] eq "transfers") {
            validate_txid($path[3])
                or return $self->http_response(404, "Unknown request");
            return $self->list_token_txs($path[1], $path[3], ($path[4] // "") eq "mempool" ? 0 : 25, ($path[4] // "") eq "chain" ? 0 : 50, $path[5]);
        }
        elsif ($path[2] eq "utxo") {
            @path == 3
                or return $self->http_response(404, "Unknown request");
            return $self->get_address_unspent($path[1]);
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
    elsif ($path[0] eq "status") {
        return $self->http_ok(node_status());
    }
    elsif ($path[0] eq "peers") {
        return $self->http_ok(peer_info());
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

sub validate_txid {
    $_[0] =~ /^[0-9a-f]{64}\z/;
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

sub vout_obj {
    my ($tx, $out) = @_;
    my $res = {
        value              => $out->value,
        scripthash         => unpack("H*", $out->scripthash),
        scripthash_address => address_by_hash($out->scripthash),
    };
    if ($tx->is_tokens) {
        $res->{token_id} = unpack("H*", $tx->token_hash || $tx->hash);
        if (length($out->data // "")) {
            if ($out->is_token_transfer) {
                $res->{token_amount} = unpack("Q<", substr($out->data, 1, 8));
                my $decimals;
                if (my $token_info = $tx->token_info) {
                    $decimals = $token_info->{decimals};
                }
                $res->{token_decimals} = $decimals // TOKEN_DEFAULT_DECIMALS;
            }
            elsif (my $token_info = $tx->unpack_token_info) {
                if ($token_info->{permissions}) {
                    $res->{token_permissions} = sprintf("0x%02x", $token_info->{permissions});
                }
            }
        }
    }
    return $res;
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
        tx_type       => $tx->type_as_text,
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
        vin  => [ map { vin_obj($_)       } @{$tx->in}  ],
        vout => [ map { vout_obj($tx, $_) } @{$tx->out} ],
        UPGRADE_POW && $tx->is_coinbase ? (
            coinbase_info => {
                block_height => $tx->up->btc_block_height,
                tx_hash      => unpack("H*", $tx->up->btc_tx_hash),
                out_num      => $tx->up->btc_out_num,
                value        => $tx->up->value,
            },
        ) : (),
        $tx->is_tokens ? ( token_id => unpack("H*", $tx->token_hash) ) : (),
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

sub get_address_stats {
    my $self = shift;
    my ($address) = @_;
    my $stats = address_stats($address)
        or return $self->http_response(404, "Incorrect address");
    $stats->{tokens} = {};
    my $tokens = all_tokens_balance($address);
    if ($tokens && %$tokens) {
        foreach my $token (keys %$tokens) {
            $stats->{tokens}->{unpack("H*", $token)} = $tokens->{$token};
        }
    }
    return $self->http_ok($stats);
}

sub list_address_txs {
    my $self = shift;
    my ($address, $chain_cnt, $mempool_cnt, $last_seen) = @_;
    my $last_seen_bin;
    if ($last_seen && $last_seen =~ /^[0-9a-f]{64}\z/) {
        $last_seen_bin = pack("H*", $last_seen);
    }
    my ($txo_chain, $txo_mempool) = get_address_txs($address, $last_seen_bin, $chain_cnt, $mempool_cnt);
    $txo_chain
        or return $self->http_response(404, "Incorrect address");
    my @tx;
    if ($mempool_cnt) {
        foreach my $tx_data (@$txo_mempool) {
            my $tx = QBitcoin::Transaction->get($tx_data->[0])
                or next;
            push @tx, tx_obj($tx);
        }
    }
    if ($chain_cnt) {
        foreach my $tx_data (@$txo_chain) {
            my $tx = QBitcoin::Transaction->get_by_hash($tx_data->[0])
                or next;
            push @tx, tx_obj($tx);
        }
    }
    return $self->http_ok(\@tx);
}

sub list_token_txs {
    my $self = shift;
    my ($address, $token_hash, $chain_cnt, $mempool_cnt, $last_seen) = @_;
    my $last_seen_bin;
    if ($last_seen && $last_seen =~ /^[0-9a-f]{64}\z/) {
        $last_seen_bin = pack("H*", $last_seen);
    }
    my ($txs_chain, $txs_mempool) = get_tokens_txs($address, pack("H*", $token_hash), $last_seen_bin, $chain_cnt, $mempool_cnt);
    $txs_chain
        or return $self->http_response(404, "Incorrect address");
    return $self->http_ok([ map { [ unpack("H*", $_->[0]), $_->[1], $_->[2] ] } @$txs_mempool, @$txs_chain ]);
}

sub get_address_unspent {
    my $self = shift;
    my ($address) = @_;

    my ($txo_chain, $txo_mempool) = get_address_utxo($address);
    $txo_chain
        or return $self->http_response(404, "Incorrect address");
    my @utxo;
    foreach my $txid (keys %$txo_chain) {
        for (my $vout = 0; $vout < @{$txo_chain->{$txid}}; $vout++) {
            my $utxo = $txo_chain->{$txid}->[$vout]
                or next;
            push @utxo, {
                txid      => unpack("H*", $txid),
                vout      => $vout,
                value     => $utxo->{value},
                height    => $utxo->{block_height},
                block_pos => $utxo->{block_pos},
                status    => "confirmed",
                defined($utxo->{token_id})    ? ( token_id          => unpack("H*", $utxo->{token_id}) ) : (),
                defined($utxo->{token_value}) ? ( token_value       => $utxo->{token_value} ) : (),
                $utxo->{token_permissions}    ? ( token_permissions => $utxo->{token_permissions} ) : (),
            }
        }
    }
    @utxo = sort { $a->{height} <=> $b->{height} || $a->{block_pos} <=> $b->{block_pos} } @utxo;
    foreach my $txid (sort { $a cmp $b } keys %$txo_mempool) { # TODO: sort by received_time
        for (my $vout = 0; $vout < @{$txo_mempool->{$txid}}; $vout++) {
            my $utxo = $txo_mempool->{$txid}->[$vout]
                or next;
            push @utxo, {
                txid   => unpack("H*", $txid),
                vout   => $vout,
                value  => $utxo->{value},
                status => "unconfirmed",
                defined($utxo->{token_id})    ? ( token_id          => unpack("H*", $utxo->{token_id}) ) : (),
                defined($utxo->{token_value}) ? ( token_value       => $utxo->{token_value} ) : (),
                $utxo->{token_permissions}    ? ( token_permissions => $utxo->{token_permissions} ) : (),
            };
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

sub node_status {
    my $best_block;
    if (defined(my $height = QBitcoin::Block->blockchain_height)) {
        $best_block = QBitcoin::Block->best_block($height);
    }
    my @mempool = QBitcoin::Transaction->mempool_list();
    my $response = {
        chain                => $config->{regtest} ? "regtest" : $config->{testnet} ? "testnet" : "main",
        blocks               => defined($best_block) ? $best_block->height+0 : -1,
        bestblockhash        => $best_block ? unpack("H*", $best_block->hash) : undef,
        weight               => $best_block ? $best_block->weight+0   : -1,
        bestblocktime        => $best_block ? $best_block->time       : -1,
        reward               => $best_block ? int($best_block->reward_fund / REWARD_DIVIDER) : 0,
        initialblockdownload => blockchain_synced() ? FALSE : TRUE,
        mempool_size         => @mempool + 0,
        mempool_bytes        => sum0(map { $_->size } @mempool) + 0,
    };
    if ($config->{regtest}) {
        if (my $genesis_block = QBitcoin::Block->best_block(0)) {
            $response->{genesistime} = $genesis_block->time;
        }
    }
    else {
        $response->{genesistime} = $config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME;
    }
    if (UPGRADE_POW) {
        my ($btc_block) = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 1);
        my $btc_scanned;
        if ($btc_block) {
            if ($btc_block->scanned) {
                $btc_scanned = $btc_block;
            }
            else {
                ($btc_scanned) = Bitcoin::Block->find(scanned => 1, -sortby => 'height DESC', -limit => 1);
            }
        }
        $response->{btc_synced}  = btc_synced() ? TRUE : FALSE,
        $response->{btc_headers} = $btc_block   ? $btc_block->height+0   : 0,
        $response->{btc_scanned} = $btc_scanned ? $btc_scanned->height+0 : 0,
        my ($coinbase) = dbh->selectrow_array("SELECT SUM(value) FROM `" . QBitcoin::Coinbase->TABLE . "` WHERE tx_out IS NOT NULL");
        $coinbase //= 0;
        $coinbase += GENESIS_REWARD if defined($best_block);
        $response->{total_coins} = $coinbase;
    }
    return $response;
}

sub peer_info {
    my @peers;
    foreach my $connection (QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN, PROTOCOL_BITCOIN)) {
        my $peer = $connection->peer;
        push @peers, {
            addr        => $connection->ip . ":" . $connection->port,
            addrlocal   => $connection->my_ip . ":" . $connection->my_port,
            inbound     => $connection->direction == DIR_IN ? TRUE : FALSE,
            protocol    => $connection->type,
            network     => "ipv4",
            createtime  => $peer->create_time,
            bytessent   => $peer->bytes_sent,
            bytesrecv   => $peer->bytes_recv,
            objsent     => $peer->obj_sent,
            objrecv     => $peer->obj_recv,
            reputation  => $peer->reputation,
        };
    }
    return \@peers;
}

1;
