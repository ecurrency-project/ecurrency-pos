package QBitcoin::Utils;
use warnings;
use strict;

# Utility functions for QBitcoin REST and RPC interfaces

use Exporter qw(import);
our @EXPORT_OK = qw(get_address_txo get_address_utxo address_received address_balance address_stats);

use List::Util qw(sum0);
use QBitcoin::Log;
use QBitcoin::ORM qw(dbh);
use QBitcoin::Address qw(scripthash_by_address);
use QBitcoin::RedeemScript;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Block;

use constant MAX_TXO_PER_ADDRESS => 10_000;

sub get_address_txo {
    my ($address) = @_;
    my $scripthash = eval { scripthash_by_address($address) }
        or return ();
    my %txo_chain;
    my $txo_cnt = 0;
    if (my $script = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        foreach my $txo (dbh->selectall_array("SELECT tx_in.hash, num, value, tx_in.block_height, tx_in.block_pos, tx_out.hash, tx_out.block_height, tx_out.block_pos FROM `" . QBitcoin::TXO->TABLE . "` JOIN `" . QBitcoin::Transaction->TABLE . "` tx_in ON (tx_in = tx_in.id) LEFT JOIN `" . QBitcoin::Transaction->TABLE . "` tx_out ON (tx_out = tx_out.id) WHERE scripthash = ? ORDER BY tx_in.block_height DESC, tx_in.block_pos DESC LIMIT ?", undef, $script->id, MAX_TXO_PER_ADDRESS)) {
            $txo_chain{$txo->[0]}->[$txo->[1]] = [ $txo->[2], $txo->[3], $txo->[4], $txo->[5], $txo->[6], $txo->[7] ]; # [ value, block_height, block_pos, spent_hash, spent_height, spent_block_pos ]
            $txo_cnt++;
        }
        if ($txo_cnt >= MAX_TXO_PER_ADDRESS) {
            Infof("Too many TXO for address %s", $address);
            return ();
        }
    }
    for (my $height = QBitcoin::Block->max_db_height + 1; $height <= QBitcoin::Block->blockchain_height; $height++) {
        my $block = QBitcoin::Block->best_block($height)
            or next;
        foreach my $tx (@{$block->transactions}) {
            for (my $num = 0; $num < @{$tx->out}; $num++) {
                my $out = $tx->out->[$num];
                next if $out->scripthash ne $scripthash;
                $txo_chain{$tx->hash}->[$num] = [ $out->value, $height, $tx->block_pos ];
            }
            foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
                @{ $txo_chain{$in->{txo}->tx_in}->[$in->{txo}->num] }[3,4,5] = ( $tx->hash, $height, $tx->block_pos );
            }
        }
    }
    my %txo_mempool;
    foreach my $tx (QBitcoin::Transaction->mempool_list()) {
        for (my $num = 0; $num < @{$tx->out}; $num++) {
            my $out = $tx->out->[$num];
            next if $out->scripthash ne $scripthash;
            $txo_mempool{$tx->hash}->[$num] = [ $out->value, undef ];
        }
        foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
            if ($txo_mempool{$in->{txo}->tx_in}) {
                $txo_mempool{$in->{txo}->tx_in}->[$in->{txo}->num]->[3] = $tx->hash;
            }
            elsif ($txo_chain{$in->{txo}->tx_in}) {
                # Unconfirmed spent displayed as spent
                $txo_chain{$in->{txo}->tx_in}->[$in->{txo}->num]->[3] = $tx->hash;
            }
        }
    }

    return wantarray ? (\%txo_chain, \%txo_mempool) : \%txo_chain;
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
    my $last_tx;
    my %fresh_inputs;
    if (my $script = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        my $result;
        if ($minconf && $blockchain_height - $minconf + 1 < $max_db_height) {
            ($last_tx) = QBitcoin::Transaction->fetch(block_height => { '<=', $blockchain_height - $minconf + 1 }, -sortby => 'id DESC', -limit => 1);
            if (defined $last_tx) {
                my $sql = "SELECT SUM(value) FROM `" . QBitcoin::TXO->TABLE . "` WHERE tx_out IS NULL and scripthash = ? AND tx_in <= ?";
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
            if (%fresh_inputs) {
                foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
                    $value -= $in->{txo}->value if exists $fresh_inputs{$in->{txo}->tx_in};
                }
            }
            if (!$minconf || $height <= $blockchain_height - $minconf + 1) {
                foreach my $out (grep { $_->scripthash eq $scripthash && $_->unspent } @{$tx->out}) {
                    $value += $out->value;
                }
            }
        }
    }
    if (%fresh_inputs || !$minconf) {
        foreach my $tx (QBitcoin::Transaction->mempool_list()) {
            if (%fresh_inputs) {
                foreach my $in (grep { $_->{txo}->scripthash eq $scripthash } @{$tx->in}) {
                    $value -= $in->{txo}->value if exists $fresh_inputs{$in->{txo}->tx_in};
                }
            }
            if (!$minconf) {
                foreach my $out (grep { $_->scripthash eq $scripthash && $_->unspent } @{$tx->out}) {
                    $value += $out->value;
                }
            }
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
        foreach my $txo (dbh->selectall_array("SELECT tx_in.hash, num, value, tx_in.block_height, tx_in.block_pos FROM `" . QBitcoin::TXO->TABLE . "` JOIN `" . QBitcoin::Transaction->TABLE . "` tx_in ON (tx_in = tx_in.id) WHERE tx_out IS NULL and scripthash = ? ORDER BY tx_in.block_height DESC, tx_in.block_pos DESC LIMIT ?", undef, $script->id, $limit // MAX_TXO_PER_ADDRESS)) {
            $txo_chain{$txo->[0]}->[$txo->[1]] = [ $txo->[2], $txo->[3], $txo->[4] ]; # [ value, block_height, block_pos ]
            $txo_cnt++;
        }
        if (!defined($limit) && $txo_cnt >= MAX_TXO_PER_ADDRESS) {
            Infof("Too many UTXO for address %s", $address);
            return undef;
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

1;
