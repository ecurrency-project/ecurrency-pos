package QBitcoin::Utils;
use warnings;
use strict;

# Utility functions for QBitcoin REST and RPC interfaces

use Exporter qw(import);
our @EXPORT_OK = qw(get_address_txo get_address_utxo);

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
                if (@{ $txo_chain{$in->{txo}->tx_in} }) {
                    delete $txo_chain{$in->{txo}->tx_in}->[$in->{txo}->num];
                    delete $txo_chain{$in->{txo}->tx_in} unless @{ $txo_chain{$in->{txo}->tx_in} };
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
            if (@{ $txo_chain{$in->{txo}->tx_in} }) {
                delete $txo_chain{$in->{txo}->tx_in}->[$in->{txo}->num];
                delete $txo_chain{$in->{txo}->tx_in} unless @{ $txo_chain{$in->{txo}->tx_in} };
            }
            elsif (@{ $txo_mempool{$in->{txo}->tx_in} }) {
                delete $txo_mempool{$in->{txo}->tx_in}->[$in->{txo}->num];
                delete $txo_mempool{$in->{txo}->tx_in} unless @{ $txo_mempool{$in->{txo}->tx_in} };
            }
        }
    }

    return wantarray ? (\%txo_chain, \%txo_mempool) : \%txo_chain;
}

1;
