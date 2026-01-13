package QBitcoin::Utils;
use warnings;
use strict;
use feature 'state';

# Utility functions for QBitcoin REST and RPC interfaces

use Exporter qw(import);
our @EXPORT_OK = qw(get_address_txs get_address_utxo address_received address_balance address_stats tokens_received tokens_balance);

use List::Util qw(sum0);
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::ORM qw(dbh);
use QBitcoin::Address qw(scripthash_by_address);
use QBitcoin::RedeemScript;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Block;

use constant MAX_TXO_PER_ADDRESS => 10_000;

# returns list of arrays [ txid, value, block_height ] for blockchain and [ txid, value, received_time ] for mempool
sub get_address_txs {
    my ($address, $last_seen, $chain_limit, $mempool_limit) = @_;
    my $scripthash = eval { scripthash_by_address($address) }
        or return ();
    $chain_limit //= MAX_TXO_PER_ADDRESS;
    $mempool_limit //= MAX_TXO_PER_ADDRESS;
    my @txs_chain;

    my ($skip_before, $skip_before_id);
    my $script = QBitcoin::RedeemScript->find(hash => $scripthash);
    if ($last_seen) {
        if ($skip_before = QBitcoin::Transaction->get($last_seen)) {
            $skip_before_id = $skip_before->id; # undef if not in DB
        }
        elsif (($skip_before) = QBitcoin::Transaction->fetch(hash => $last_seen)) {
            $skip_before_id = $skip_before->{id};
        }
    }

    my @txs_inmem;
    if (!$skip_before_id) {
        my $in_skip = $skip_before ? 1 : 0;
        for (my $height = QBitcoin::Block->blockchain_height; $height > QBitcoin::Block->max_db_height; $height--) {
            my $block = QBitcoin::Block->best_block($height)
                or next;
            foreach my $tx (reverse @{$block->transactions}) {
                if ($in_skip) {
                    if ($tx->hash eq $last_seen) {
                        $in_skip = 0;
                    }
                    next;
                }
                my $tx_data;
                for (my $num = 0; $num < @{$tx->out}; $num++) {
                    my $out = $tx->out->[$num];
                    next if $out->scripthash ne $scripthash;
                    if ($tx_data) {
                        $tx_data->[1] += $out->value;
                    }
                    else {
                        $tx_data= [ $tx->hash, $out->value, $height, $tx->block_pos ];
                    }
                }
                foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
                    if ($tx_data) {
                        $tx_data->[1] -= $in->{txo}->value;
                    }
                    else {
                        $tx_data = [ $tx->hash, -$in->{txo}->value, $height, $tx->block_pos ];
                    }
                }
                push @txs_inmem, $tx_data if $tx_data;
            }
        }
    }

    if (@txs_inmem < $chain_limit && $script) {
        my @txs_in = dbh->selectall_array("SELECT hash, amount, block_height, block_pos FROM `" . QBitcoin::Transaction->TABLE . "` tx JOIN (SELECT tx_in, SUM(value) AS amount FROM `" . QBitcoin::TXO->TABLE . "` txo WHERE scripthash = ? AND (? IS NULL OR tx_in < ?) GROUP BY tx_in ORDER BY tx_in DESC LIMIT ?) AS t ON (tx_in = id)", undef, $script->id, $skip_before_id, $skip_before_id, $chain_limit);
        my @txs_out = dbh->selectall_array("SELECT hash, amount, block_height, block_pos FROM `" . QBitcoin::Transaction->TABLE . "` tx JOIN (SELECT tx_out, -SUM(value) AS amount FROM `" . QBitcoin::TXO->TABLE . "` txo WHERE scripthash = ? AND tx_out IS NOT NULL AND (? IS NULL OR tx_out < ?) GROUP BY tx_out ORDER BY tx_out DESC LIMIT ?) AS t ON (tx_out = id)", undef, $script->id, $skip_before_id, $skip_before_id, $chain_limit);
        my %txs_in = map { $_->[0] => $_ } @txs_in;
        foreach my $tx (@txs_out) {
            if (exists $txs_in{$tx->[0]}) {
                $txs_in{$tx->[0]}->[1] += $tx->[1];
            }
            else {
                push @txs_in, $tx;
            }
        }
        undef @txs_out;
        undef %txs_in;
        @txs_chain = map [ $_->[0], $_->[1], $_->[2] ],
            sort { $b->[2] <=> $a->[2] || $b->[3] <=> $a->[3] }
                @txs_inmem, @txs_in;
    }
    else {
        @txs_chain = map [ $_->[0], $_->[1], $_->[2] ], @txs_inmem;
    }
    splice @txs_chain, $chain_limit if @txs_chain > $chain_limit;
    undef @txs_inmem;

    my @txs_mempool;
    foreach my $tx (QBitcoin::Transaction->mempool_list()) {
        my $tx_data;
        for (my $num = 0; $num < @{$tx->out}; $num++) {
            my $out = $tx->out->[$num];
            next if $out->scripthash ne $scripthash;
            if ($tx_data) {
                $tx_data->[1] += $out->value;
            }
            else {
                $tx_data = [ $tx->hash, $out->value, $tx->received_time ];
            }
        }
        foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
            if ($tx_data) {
                $tx_data->[1] -= $in->{txo}->value;
            }
            else {
                $tx_data = [ $tx->hash, -$in->{txo}->value, $tx->received_time ];
            }
        }
        push @txs_mempool, $tx_data if $tx_data;
    }

    return (\@txs_chain, \@txs_mempool);
}

sub address_stats {
    my ($address) = @_;
    my $scripthash = eval { scripthash_by_address($address) }
        or return undef;
    my ($funded_sum, $funded_cnt, $spent_sum, $spent_cnt, $tx_cnt) = (0,0,0,0,0);
    my $max_db_height = QBitcoin::Block->max_db_height;
    my $blockchain_height = QBitcoin::Block->blockchain_height;
    if (my $script = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        my $sql = "SELECT IFNULL(SUM(value), 0), COUNT(*), IFNULL(SUM(IF(tx_out IS NULL, 0, value)), 0), COUNT(tx_out), COUNT(DISTINCT tx_in)+COUNT(DISTINCT tx_out) FROM `" . QBitcoin::TXO->TABLE . "` WHERE scripthash = ?";
        my ($result) = dbh->selectall_array($sql, undef, $script->id);
        ($funded_sum, $funded_cnt, $spent_sum, $spent_cnt, $tx_cnt) = @$result;
        # Calculate transactions with both inputs and outputs to this address
        my ($res2) = dbh->selectall_array("SELECT COUNT(DISTINCT t1.tx_in) FROM `" . QBitcoin::TXO->TABLE . "` t1 JOIN `" . QBitcoin::TXO->TABLE . "` t2 ON (t1.tx_in = t2.tx_out AND t1.scripthash = t2.scripthash) WHERE t1.scripthash = ?", undef, $script->id);
        $tx_cnt -= $res2->[0];
    }
    for (my $height = $max_db_height + 1; $height <= $blockchain_height; $height++) {
        my $block = QBitcoin::Block->best_block($height)
            or next;
        foreach my $tx (@{$block->transactions}) {
            my $tx_involved = 0;
            foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
                $spent_sum += $in->{txo}->value;
                $spent_cnt++;
                $tx_involved = 1;
            }
            foreach my $out (grep { $_->scripthash eq $scripthash } @{$tx->out}) {
                $funded_sum += $out->value;
                $funded_cnt++;
                $tx_involved = 1;
            }
            $tx_cnt++ if $tx_involved;
        }
    }
    my ($mempool_funded_sum, $mempool_funded_cnt, $mempool_spent_sum, $mempool_spent_cnt, $mempool_tx_cnt) = (0,0,0,0,0);
    foreach my $tx (QBitcoin::Transaction->mempool_list()) {
        my $tx_involved = 0;
        foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
            $mempool_spent_sum += $in->{txo}->value;
            $mempool_spent_cnt++;
            $tx_involved = 1;
        }
        foreach my $out (grep { $_->scripthash eq $scripthash } @{$tx->out}) {
            $mempool_funded_sum += $out->value;
            $mempool_funded_cnt++;
            $tx_involved = 1;
        }
        $mempool_tx_cnt++ if $tx_involved;
    }

    return {
        chain_stats   => {
            funded_txo_sum   => $funded_sum,
            funded_txo_count => $funded_cnt,
            spent_txo_sum    => $spent_sum,
            spent_txo_count  => $spent_cnt,
            tx_count         => $tx_cnt,
        },
        mempool_stats => {
            funded_txo_sum   => $mempool_funded_sum,
            funded_txo_count => $mempool_funded_cnt,
            spent_txo_sum    => $mempool_spent_sum,
            spent_txo_count  => $mempool_spent_cnt,
            tx_count         => $mempool_tx_cnt,
        },
    };
}

sub address_received {
    my ($address, $minconf) = @_;
    my $scripthash = eval { scripthash_by_address($address) }
        or return undef;
    my $value = 0;
    my $max_db_height = QBitcoin::Block->max_db_height;
    my $blockchain_height = QBitcoin::Block->blockchain_height;
    if (my $script = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        my $result;
        if ($minconf && $blockchain_height - $minconf + 1 < $max_db_height) {
            my $sql = "SELECT SUM(value) FROM `" . QBitcoin::TXO->TABLE . "` JOIN `" . QBitcoin::Transaction->TABLE . "` tx_in ON (tx_in = tx_in.id) WHERE scripthash = ? AND tx_in.block_height <= ?";
            ($result) = dbh->selectall_array($sql, undef, $script->id, $blockchain_height - $minconf + 1);
        }
        else {
            my $sql = "SELECT SUM(value) FROM `" . QBitcoin::TXO->TABLE . "` WHERE scripthash = ?";
            ($result) = dbh->selectall_array($sql, undef, $script->id);
        }
        $value = $result->[0] // 0;
    }
    if ($minconf && $blockchain_height - $minconf + 1 <= $max_db_height) {
        return $value;
    }

    for (my $height = $max_db_height + 1; $height <= $blockchain_height - $minconf + 1; $height++) {
        my $block = QBitcoin::Block->best_block($height)
            or next;
        foreach my $tx (@{$block->transactions}) {
            $value += sum0 map { $_->value } grep { $_->scripthash eq $scripthash } @{$tx->out};
        }
    }
    if (!$minconf) {
        foreach my $tx (QBitcoin::Transaction->mempool_list()) {
            $value += sum0 map { $_->value } grep { $_->scripthash eq $scripthash } @{$tx->out};
        }
    }

    return $value;
}

sub address_balance {
    my ($address, $minconf) = @_;
    my $scripthash = eval { scripthash_by_address($address) }
        or return undef;
    my $value = 0;
    my $max_db_height = QBitcoin::Block->max_db_height;
    my $blockchain_height = QBitcoin::Block->blockchain_height;
    my %fresh_inputs;
    if (my $script = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        my $result;
        if ($minconf && $blockchain_height - $minconf + 1 < $max_db_height) {
            my ($last_tx) = QBitcoin::Transaction->fetch(block_height => { '<=', $blockchain_height - $minconf + 1 }, -sortby => 'id DESC', -limit => 1);
            if (defined $last_tx) {
                my $sql = "SELECT SUM(value) FROM `" . QBitcoin::TXO->TABLE . "` WHERE tx_out IS NULL AND scripthash = ? AND tx_in <= ?";
                ($result) = dbh->selectall_array($sql, undef, $script->id, $last_tx->{id});
                # Store inputs that have not enough confirmations to exclude them later
                my $fresh_inputs_sql = "SELECT hash FROM `" . QBitcoin::TXO->TABLE . "` JOIN `" . QBitcoin::Transaction->TABLE . "` ON (id = tx_in) WHERE scripthash = ? AND tx_out IS NULL AND tx_in > ?";
                %fresh_inputs = map { $_->[0] => 1 } dbh->selectall_array($fresh_inputs_sql, undef, $script->id, $last_tx->{id});
            }
            else {
                $result = [0];
            }
        }
        else {
            my $sql = "SELECT SUM(value) FROM `" . QBitcoin::TXO->TABLE . "` WHERE tx_out IS NULL and scripthash = ?";
            ($result) = dbh->selectall_array($sql, undef, $script->id);
        }
        $value = $result->[0] // 0;
    }

    for (my $height = $max_db_height + 1; $height <= $blockchain_height; $height++) {
        my $block = QBitcoin::Block->best_block($height)
            or next;
        foreach my $tx (@{$block->transactions}) {
            foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
                next if exists $fresh_inputs{$in->{txo}->tx_in};
                my $first_spent = $in->{txo}->tx_out;
                ($first_spent) = sort { $a cmp $b } map { $_->hash } $in->{txo}->spent_list unless $first_spent;
                next if $first_spent && $first_spent ne $tx->hash;
                $value -= $in->{txo}->value;
            }
            if (!$minconf || $height <= $blockchain_height - $minconf + 1) {
                foreach my $out (grep { $_->scripthash eq $scripthash } @{$tx->out}) {
                    $value += $out->value;
                }
            }
            elsif (grep { $_->scripthash eq $scripthash } @{$tx->out}) {
                $fresh_inputs{$tx->hash} = 1;
            }
        }
    }

    foreach my $tx (QBitcoin::Transaction->mempool_list()) {
        if (!$minconf) {
            foreach my $out (grep { $_->scripthash eq $scripthash } @{$tx->out}) {
                $value += $out->value;
            }
        }
        elsif (grep { $_->scripthash eq $scripthash } @{$tx->out}) {
            $fresh_inputs{$tx->hash} = 1;
        }
    }
    foreach my $tx (QBitcoin::Transaction->mempool_list()) {
        foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
            next if exists $fresh_inputs{$in->{txo}->tx_in};
            my $first_spent = $in->{txo}->tx_out;
            ($first_spent) = sort { $a cmp $b } map { $_->hash } $in->{txo}->spent_list unless $first_spent;
            next if $first_spent && $first_spent ne $tx->hash;
            $value -= $in->{txo}->value;
        }
    }

    return $value;
}

sub get_address_utxo {
    my ($address, $limit) = @_;
    my $scripthash = eval { scripthash_by_address($address) }
        or return ();
    my %txo_chain;
    my $txo_cnt = 0;
    if (my $script = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        foreach my $txo (dbh->selectall_array("SELECT tx_in.hash, num, value, tx_in.block_height, tx_in.block_pos FROM `" . QBitcoin::TXO->TABLE . "` JOIN `" . QBitcoin::Transaction->TABLE . "` tx_in ON (tx_in = tx_in.id) WHERE tx_out IS NULL AND scripthash = ? ORDER BY tx_in.block_height DESC, tx_in.block_pos DESC LIMIT ?", undef, $script->id, $limit // MAX_TXO_PER_ADDRESS)) {
            $txo_chain{$txo->[0]}->[$txo->[1]] = [ $txo->[2], $txo->[3], $txo->[4] ]; # [ value, block_height, block_pos ]
            $txo_cnt++;
        }
        if (!defined($limit) && $txo_cnt >= MAX_TXO_PER_ADDRESS) {
            Infof("Too many UTXO for address %s", $address);
        }
    }
    for (my $height = QBitcoin::Block->max_db_height + 1; $height <= QBitcoin::Block->blockchain_height; $height++) {
        my $block = QBitcoin::Block->best_block($height)
            or next;
        foreach my $tx (@{$block->transactions}) {
            for (my $num = 0; $num < @{$tx->out}; $num++) {
                my $out = $tx->out->[$num];
                next if $out->scripthash ne $scripthash;
                $txo_chain{$tx->hash}->[$num] = [ $out->value, $height, $tx->block_pos ] if $out->unspent;
            }
            foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
                my $txid = $in->{txo}->tx_in;
                if (exists $txo_chain{$txid}) {
                    $txo_chain{$txid}->[$in->{txo}->num] = undef;
                    delete $txo_chain{$txid} unless grep { defined } @{ $txo_chain{$txid} };
                }
            }
        }
    }
    my %txo_mempool;
    foreach my $tx (QBitcoin::Transaction->mempool_list()) {
        for (my $num = 0; $num < @{$tx->out}; $num++) {
            my $out = $tx->out->[$num];
            next if $out->scripthash ne $scripthash;
            $txo_mempool{$tx->hash}->[$num] = [ $out->value ] if $out->unspent;
        }
        foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
            my $txid = $in->{txo}->tx_in;
            if ($txo_chain{$txid}) {
                $txo_chain{$txid}->[$in->{txo}->num] = undef;
                delete $txo_chain{$txid} unless grep { defined } @{ $txo_chain{$txid} };
            }
            elsif ($txo_mempool{$txid}) {
                $txo_mempool{$txid}->[$in->{txo}->num] = undef;
                delete $txo_mempool{$txid} unless grep { defined } @{ $txo_mempool{$txid} };
            }
        }
    }

    return wantarray ? (\%txo_chain, \%txo_mempool) : \%txo_chain;
}

sub _unpack_data_value {
    if (dbh->get_info(17) eq "SQLite") {
        my $sum = "";
        foreach my $byte (0 .. 7) {
            $sum .= " + " if $byte;
            $sum .= "((INSTR('0123456789ABCDEF', SUBSTR(HEX(data), " . ($byte * 2 + 3) . ", 1)) - 1) << " . ($byte * 8 + 4) . ") + ";
            $sum .= "((INSTR('0123456789ABCDEF', SUBSTR(HEX(data), " . ($byte * 2 + 4) . ", 1)) - 1) << " . ($byte * 8) . ")";
        }
        return $sum;
    }
    elsif (dbh->get_info(17) eq "PostgreSQL") {
        return "GET_BYTE(data, 1)::BIGINT + (GET_BYTE(data, 2)::BIGINT << 8) + (GET_BYTE(data, 3)::BIGINT << 16) + (GET_BYTE(data, 4)::BIGINT << 24) + (GET_BYTE(data, 5)::BIGINT << 32) + (GET_BYTE(data, 6)::BIGINT << 40) + (GET_BYTE(data, 7)::BIGINT << 48) + (GET_BYTE(data, 8)::BIGINT << 56)";
    }
    else { # MySQL
        return "CAST(CONV(HEX(REVERSE(SUBSTR(data, 2, 8))), 16, 10) AS UNSIGNED)";
    }
}

sub tokens_received {
    my ($address, $tokens, $minconf) = @_;
    my $scripthash = eval { scripthash_by_address($address) }
        or return undef;
    my $value = 0;
    my $max_db_height = QBitcoin::Block->max_db_height;
    my $blockchain_height = QBitcoin::Block->blockchain_height;
    if ((my $script = QBitcoin::RedeemScript->find(hash => $scripthash)) && (my ($token_tx) = QBitcoin::Transaction->fetch(hash => $tokens))) {
        my $result;
        state $unpack_value = _unpack_data_value();
        my $sql = "SELECT IFNULL(SUM($unpack_value), 0) AS value FROM `" . QBitcoin::TXO->TABLE . "` JOIN `" . QBitcoin::Transaction->TABLE . "` tx_in ON (tx_in = tx_in.id) WHERE scripthash = ? AND tx_in.tx_type = ? AND IFNULL(tx_in.token_id, tx_in.id) = ?+0 AND LENGTH(data) = 9 AND SUBSTR(data, 1, 1) = ?";
        if ($minconf && $blockchain_height - $minconf + 1 < $max_db_height) {
            $sql .= " AND tx_in.block_height <= ?";
            ($result) = dbh->selectall_array($sql, undef, $script->id, TX_TYPE_TOKENS, $token_tx->{id}, TOKEN_TXO_TYPE_TRANSFER, $blockchain_height - $minconf + 1);
        }
        else {
            ($result) = dbh->selectall_array($sql, undef, $script->id, TX_TYPE_TOKENS, $token_tx->{id}, TOKEN_TXO_TYPE_TRANSFER);
        }
        $value = $result->[0] // 0;
    }
    if ($minconf && $blockchain_height - $minconf + 1 <= $max_db_height) {
        return $value;
    }

    for (my $height = $max_db_height + 1; $height <= $blockchain_height - $minconf + 1; $height++) {
        my $block = QBitcoin::Block->best_block($height)
            or next;
        foreach my $tx (grep { $_->is_tokens && ($_->token_hash || $_->hash) eq $tokens } @{$block->transactions}) {
            $value += sum0 map { unpack("Q<", substr($_->data, 1, 8)) }
                grep { $_->scripthash eq $scripthash && length($_->data) == 9 && substr($_->data, 0, 1) eq TOKEN_TXO_TYPE_TRANSFER }
                    @{$tx->out};
        }
    }
    if (!$minconf) {
        foreach my $tx (grep { $_->is_tokens && ($_->token_hash || $_->hash) eq $tokens } QBitcoin::Transaction->mempool_list()) {
            $value += sum0 map { unpack("Q<", substr($_->data, 1, 8)) }
                grep { $_->scripthash eq $scripthash && length($_->data) == 9 && substr($_->data, 0, 1) eq TOKEN_TXO_TYPE_TRANSFER }
                    @{$tx->out};
        }
    }

    return $value;
}

sub tokens_balance {
    my ($address, $tokens, $minconf) = @_;
    my $scripthash = eval { scripthash_by_address($address) }
        or return undef;
    my $value = 0;
    my $max_db_height = QBitcoin::Block->max_db_height;
    my $blockchain_height = QBitcoin::Block->blockchain_height;
    my %fresh_inputs;
    my $token_id;
    if ((my $script = QBitcoin::RedeemScript->find(hash => $scripthash)) && (my ($token_tx) = QBitcoin::Transaction->fetch(hash => $tokens))) {
        $token_id = $token_tx->{id};
        my $result;
        my $last_tx;
        state $unpack_value = _unpack_data_value();
        if ($minconf && $blockchain_height - $minconf + 1 < $max_db_height) {
            ($last_tx) = QBitcoin::Transaction->fetch(block_height => { '<=', $blockchain_height - $minconf + 1 }, -sortby => 'id DESC', -limit => 1);
        }
        my $sql = "SELECT SUM($unpack_value) FROM `" . QBitcoin::TXO->TABLE . "` AS txo JOIN `" . QBitcoin::Transaction->TABLE . "` AS tx_in ON (tx_in.id = txo.tx_in) WHERE tx_out IS NULL AND scripthash = ? AND tx_in.tx_type = ? AND IFNULL(tx_in.token_id, tx_in.id) = ?+0 AND LENGTH(data) = 9 AND SUBSTR(data, 1, 1) = ?";
        if (defined $last_tx) {
            $sql .= " AND tx_in <= ?";
            ($result) = dbh->selectall_array($sql, undef, $script->id, TX_TYPE_TOKENS, $token_id, TOKEN_TXO_TYPE_TRANSFER, $last_tx->{id});
            # Store inputs that have not enough confirmations to exclude them later
            my $fresh_inputs_sql = "SELECT hash FROM `" . QBitcoin::TXO->TABLE . "` JOIN `" . QBitcoin::Transaction->TABLE . "` ON (id = tx_in) WHERE scripthash = ? AND tx_out IS NULL AND tx_in > ?";
            %fresh_inputs = map { $_->[0] => 1 } dbh->selectall_array($fresh_inputs_sql, undef, $script->id, $last_tx->{id});
        }
        else {
            ($result) = dbh->selectall_array($sql, undef, $script->id, TX_TYPE_TOKENS, $token_id, TOKEN_TXO_TYPE_TRANSFER);
        }
        $value = $result->[0] // 0;
    }

    for (my $height = $max_db_height + 1; $height <= $blockchain_height; $height++) {
        my $block = QBitcoin::Block->best_block($height)
            or next;
        foreach my $tx (@{$block->transactions}) {
            foreach my $in (grep { $_->{txo}->scripthash eq $scripthash && length($_->{txo}->data) == 9 && substr($_->{txo}->data, 0, 1) eq TOKEN_TXO_TYPE_TRANSFER } @{$tx->in}) {
                next if exists $fresh_inputs{$in->{txo}->tx_in};
                my $first_spent = $in->{txo}->tx_out;
                ($first_spent) = sort { $a cmp $b } map { $_->hash } $in->{txo}->spent_list unless $first_spent;
                next if $first_spent && $first_spent ne $tx->hash;
                # Decrease value if it was correct tokens output, i.e if $_->{txo}->tx_in is tokens transaction with correct token id
                if (my $tx_in = QBitcoin::Transaction->get($in->{txo}->tx_in)) {
                    next if !$tx_in->is_tokens || ( ($tx_in->token_hash || $tx_in->hash) ne $tokens );
                }
                else {
                    my ($tx_in) = QBitcoin::Transaction->fetch(hash => $in->{txo}->tx_in);
                    next if $tx_in->{tx_type} != TX_TYPE_TOKENS || ($tx_in->{token_id} || $tx_in->{id}) != $token_id;
                }
                $value -= unpack("Q<", substr($in->{txo}->data, 1, 8));
            }
            if ($tx->is_tokens && ($tx->token_hash || $tx->hash) eq $tokens) {
                if (!$minconf || $height <= $blockchain_height - $minconf + 1) {
                    foreach my $out (grep { $_->scripthash eq $scripthash && length($_->data) == 9 && substr($_->data, 0, 1) eq TOKEN_TXO_TYPE_TRANSFER } @{$tx->out}) {
                        $value += unpack("Q<", substr($out->data, 1, 8));
                    }
                }
                elsif (grep { $_->scripthash eq $scripthash } @{$tx->out}) {
                    $fresh_inputs{$tx->hash} = 1;
                }
            }
        }
    }
    foreach my $tx (grep { $_->is_tokens && ($_->token_hash || $_->hash) eq $tokens } QBitcoin::Transaction->mempool_list()) {
        if (!$minconf) {
            foreach my $out (grep { $_->scripthash eq $scripthash && length($_->data) == 9 && substr($_->data, 0, 1) eq TOKEN_TXO_TYPE_TRANSFER } @{$tx->out}) {
                $value += unpack("Q<", substr($out->data, 1, 8));
            }
        }
        elsif (grep { $_->scripthash eq $scripthash } @{$tx->out}) {
            $fresh_inputs{$tx->hash} = 1;
        }
    }
    foreach my $tx (QBitcoin::Transaction->mempool_list()) {
        foreach my $in (grep { $_->{txo}->scripthash eq $scripthash && length($_->{txo}->data) == 9 && substr($_->{txo}->data, 0, 1) eq TOKEN_TXO_TYPE_TRANSFER } @{$tx->in}) {
            next if exists $fresh_inputs{$in->{txo}->tx_in};
            my $first_spent = $in->{txo}->tx_out;
            ($first_spent) = sort { $a cmp $b } map { $_->hash } $in->{txo}->spent_list unless $first_spent;
            next if $first_spent && $first_spent ne $tx->hash;
            # Decrease value if it was correct tokens output, i.e if $_->{txo}->tx_in is tokens transaction with correct token id
            if (my $tx_in = QBitcoin::Transaction->get($in->{txo}->tx_in)) {
                next if !$tx_in->is_tokens || ( ($tx_in->token_hash || $tx_in->hash) ne $tokens );
            }
            else {
                my ($tx_in) = QBitcoin::Transaction->fetch(hash => $in->{txo}->tx_in);
                next if $tx_in->{tx_type} != TX_TYPE_TOKENS || ($tx_in->{token_id} || $tx_in->{id}) != $token_id;
            }
            $value -= unpack("Q<", substr($in->{txo}->data, 1, 8));
        }
    }

    return $value;
}

1;
