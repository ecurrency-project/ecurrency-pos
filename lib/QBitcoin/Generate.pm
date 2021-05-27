package QBitcoin::Generate;
use warnings;
use strict;

use List::Util qw(sum);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Mempool;
use QBitcoin::Block;
use QBitcoin::OpenScript;
use QBitcoin::TXO;
use QBitcoin::MyAddress qw(my_address);
use QBitcoin::Generate::Control;

my %MY_UTXO;

sub load_utxo {
    my $class = shift;
    foreach my $my_address (my_address()) {
        my @script_data = QBitcoin::OpenScript->script_for_address($my_address);
        if (my @script = QBitcoin::OpenScript->find(data => \@script_data)) {
            foreach my $utxo (QBitcoin::TXO->find(open_script => [ map { $_->id } @script ], tx_out => undef)) {
                $utxo->save();
                $utxo->add_my_utxo(); # MB already added during fetch last INCORE blocks, it's ok b/c it's the same TXO object
            }
        }
    }
    Infof("My UTXO loaded, total %u", scalar QBitcoin::TXO->my_utxo());
}

sub my_close_script {
    my $class = shift;
    my ($open_script) = @_;
    # TODO
    return scalar my_address();
}

sub sign_my_transaction {
    my $tx = shift;
    # TODO
}

sub generated_height {
    my $class = shift;
    return QBitcoin::Generate::Control->generated_height;
}

sub txo_confirmed {
    my ($txo) = @_;
    my $tx = QBitcoin::Transaction->get_by_hash($txo->tx_in)
        or die "No input transaction " . $txo->tx_in_log . " for my utxo\n";
    return $tx->block_height;
}

sub make_stake_tx {
    my ($fee) = @_;

    my @my_txo = grep { txo_confirmed($_) } QBitcoin::TXO->my_utxo()
        or return undef;
    my $my_amount = sum map { $_->value } @my_txo;
    my ($my_address) = my_address(); # first one
    my $out = QBitcoin::TXO->new_txo(
        value       => $my_amount + $fee,
        open_script => QBitcoin::OpenScript->script_for_address($my_address),
    );
    my $tx = QBitcoin::Transaction->new(
        in            => [ map { txo => $_, close_script => my_close_script($_->open_script) }, @my_txo ],
        out           => [ $out ],
        fee           => -$fee,
        received_time => time(),
    );
    sign_my_transaction($tx);
    $tx->size = length $tx->serialize;
    return $tx;
}

sub generate {
    my $class = shift;
    my ($height) = @_;
    my $prev_block;
    if ($height > 0) {
        $prev_block = QBitcoin::Block->best_block($height-1);
    }

    my $stake_tx = make_stake_tx(0);
    my @transactions = QBitcoin::Mempool->choose_for_block($stake_tx);
    if (@transactions && $transactions[0]->fee > 0) {
        return unless $stake_tx;
        my $fee = sum map { $_->fee } @transactions;
        # Generate new stake_tx with correct output value
        $stake_tx = make_stake_tx($fee);
        Infof("Generated stake tx %s with input amount %u, consume %u fee", $stake_tx->hash_out,
            sum(map { $_->{txo}->value } @{$stake_tx->in}), -$stake_tx->fee);
        QBitcoin::TXO->save_all($stake_tx->hash, $stake_tx->out);
        $stake_tx->receive();
        unshift @transactions, $stake_tx;
    }
    my $generated = QBitcoin::Block->new({
        height       => $height,
        prev_hash    => $prev_block ? $prev_block->hash : undef,
        transactions => \@transactions,
    });
    $generated->weight = $generated->self_weight + ( $prev_block ? $prev_block->weight : 0 );
    my $data = $generated->serialize;
    $generated->hash = $generated->calculate_hash($data);
    QBitcoin::Generate::Control->generated_height($height);
    Debugf("Generated block height %u weight %u, %u transactions", $height, $generated->weight, scalar(@transactions));
    $generated->receive();
}

1;
