package QBitcoin::Utils;
use warnings;
use strict;

# Utility functions for QBitcoin REST and RPC interfaces

use Exporter qw(import);
our @EXPORT_OK = qw(get_address_txo);

use Tie::IxHash;
use QBitcoin::ORM qw(dbh);
use QBitcoin::Address qw(scripthash_by_address);
use QBitcoin::RedeemScript;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Block;

sub get_address_txo {
    my ($address) = @_;
    my $scripthash = eval { scripthash_by_address($address) }
        or return ();
    my %txo_chain;
    tie %txo_chain, "Tie::IxHash"; # preserve order of keys
    if (my $script = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        foreach my $txo (dbh->selectall_array("SELECT tx.hash, num, tx_out, value FROM `" . QBitcoin::TXO->TABLE . "` JOIN `" . QBitcoin::Transaction->TABLE . "` tx ON (tx_in = tx.id) WHERE scripthash = ? ORDER BY block_height ASC, block_pos ASC", undef, $script->id)) {
            $txo_chain{$txo->[0]}->[$txo->[1]] = [ $txo->[2], $txo->[3] ];
        }
    }
    for (my $height = QBitcoin::Block->max_db_height + 1; $height <= QBitcoin::Block->blockchain_height; $height++) {
        my $block = QBitcoin::Block->best_block($height)
            or next;
        foreach my $tx (@{$block->transactions}) {
            foreach my $in (@{$tx->in}) {
                next if $in->{txo}->scripthash ne $scripthash;
                $txo_chain{$in->{txo}->tx_in}->[$in->{txo}->num]->[0] = $tx->hash;
            }
            for (my $num = 0; $num < @{$tx->out}; $num++) {
                my $out = $tx->out->[$num];
                next if $out->scripthash ne $scripthash;
                $txo_chain{$tx->hash}->[$num] = [ undef, $out->value ];
            }
        }
    }
    my %txo_mempool;
    tie %txo_mempool, "Tie::IxHash";
    foreach my $tx (QBitcoin::Transaction->mempool_list()) {
        foreach my $in (@{$tx->in}) {
            next if $in->{txo}->scripthash ne $scripthash;
            if ($txo_mempool{$in->{txo}->tx_in}) {
                $txo_mempool{$in->{txo}->tx_in}->[$in->{txo}->num]->[0] = $tx->hash;
            }
            elsif ($txo_chain{$in->{txo}->tx_in}) {
                # Unconfirmed spent display as spent
                $txo_chain{$in->{txo}->tx_in}->[$in->{txo}->num]->[0] = $tx->hash;
            }
        }
        for (my $num = 0; $num < @{$tx->out}; $num++) {
            my $out = $tx->out->[$num];
            next if $out->scripthash ne $scripthash;
            $txo_mempool{$tx->hash}->[$num] = [ undef, $out->value ];
        }
    }
    return (\%txo_chain, \%txo_mempool);
}

1;
