package QBitcoin::Generate;
use warnings;
use strict;
use feature 'state';

use List::Util qw(sum0);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::Mempool;
use QBitcoin::Block;
use QBitcoin::RedeemScript;
use QBitcoin::TXO;
use QBitcoin::Coinbase;
use QBitcoin::Address qw(scripthash_by_address);
use QBitcoin::MyAddress qw(my_address);
use QBitcoin::Transaction;
use QBitcoin::ValueUpgraded qw(level_by_total);
use QBitcoin::Generate::Control;

sub load_utxo {
    my $class = shift;
    foreach my $my_address (my_address()) {
        $class->load_address_utxo($my_address);
    }
}

sub load_address_utxo {
    my $class = shift;
    my ($my_address) = @_;
    my @scripthash = scripthash_by_address($my_address->address);
    my $count = 0;
    my $value = 0;
    # add cached utxo as my
    foreach my $scripthash (@scripthash) {
        foreach my $utxo (QBitcoin::TXO->get_scripthash_utxo($scripthash)) {
            # ignore unconfirmed utxo
            if (my $tx = QBitcoin::Transaction->get($utxo->tx_in)) {
                next unless $tx->block_height;
            }
            else {
                next if QBitcoin::Transaction->has_pending($utxo->tx_in);
            }
            $utxo->add_my_utxo();
            $count++;
            $value += $utxo->value;
        }
    }
    if (my @script = QBitcoin::RedeemScript->find(hash => \@scripthash)) {
        foreach my $utxo (grep { !$_->is_cached } QBitcoin::TXO->find(scripthash => [ map { $_->id } @script ], tx_out => undef)) {
            $utxo->save();
            $utxo->add_my_utxo();
            $count++;
            $value += $utxo->value;
        }
    }
    Infof("My UTXO for %s loaded, found %u with amount %lu", $my_address->address, $count, $value);
}

sub generated_time {
    my $class = shift;
    return QBitcoin::Generate::Control->generated_time;
}

sub txo_confirmed {
    my ($txo) = @_;
    my $block_height = QBitcoin::Transaction->check_by_hash($txo->tx_in)
        or die "No input transaction " . $txo->tx_in_str . " for my utxo\n";
    return $block_height >= 0;
}

sub make_out_join {
    my ($reward, $my_txo) = @_;

    my $my_address;
    if ($config->{sign_alg}) {
        foreach my $sign_alg (split(/\s+/, $config->{sign_alg})) {
            foreach my $addr (my_address()) {
                if (grep { $_ eq $sign_alg } $addr->algo) {
                    $my_address = $addr;
                    last;
                }
            }
            last if $my_address;
        }
    }
    $my_address //= (my_address())[0]
        or return ();
    my $my_amount = sum0 map { $_->value } @$my_txo;
    my $out = QBitcoin::TXO->new_txo(
        value      => $my_amount + $reward,
        scripthash => scalar(scripthash_by_address($my_address->address)),
    );
    return $out;
}

sub my_txo_by_address {
    my ($my_txo) = @_;
    if (@$my_txo == 1) {
        # The most common case, only one my_txo
        # Weight is not important here, so use 1
        return [ $my_txo->[0]->scripthash, $my_txo->[0]->value, 1 ];
    }
    my $time = timeslot(time());
    my %my;
    foreach my $my_txo (@$my_txo) {
        my $my = $my{$my_txo->scripthash} //= [ 0, 0 ];
        $my->[0] += $my_txo->value;
        $my->[1] += $my_txo->value * ($time - QBitcoin::Transaction->txo_time($my_txo));
    }
    return (
        sort { $b->[2] <=> $a->[2] || $b->[1] <=> $a->[1] || $a->[0] cmp $b->[0] }
        map { [ $_, $my{$_}->[0], $my{$_}->[1] ] } keys %my
    );
}

sub make_out_separate {
    my ($reward, $my_txo) = @_;
    my ($my_best) = my_txo_by_address($my_txo);
    @$my_txo = grep { $_->scripthash eq $my_best->[0] } @$my_txo;
    return QBitcoin::TXO->new_txo(
        value      => $my_best->[1] + $reward,
        scripthash => $my_best->[0],
    );
}

sub make_out_union {
    my ($reward, $my_txo) = @_;
    my @my = my_txo_by_address($my_txo);
    my $total_weight = sum0 map { $_->[2] } @my;
    my @out;
    my $reward_remain = $reward;
    my %remove_scripthash;
    for (my $i = $#my; $i >= 0; $i--) {
        my $reward_part = $i > 0 ? int($reward * $my[$i]->[2] / $total_weight + 0.5) : $reward_remain;
        if ($reward > 0 && $reward_part == 0) {
            # Remove utxo related to this address from the @$my_txo list
            $remove_scripthash{$my[$i]->[0]} = 1;
            next;
        }
        $reward_remain -= $reward_part;
        push @out, QBitcoin::TXO->new_txo(
            value      => $my[$i]->[1] + $reward_part,
            scripthash => $my[$i]->[0],
        );
    }
    if (%remove_scripthash) {
        # Remove utxo related to this address from the @$my_txo list
        @$my_txo = grep { !$remove_scripthash{$_->scripthash} } @$my_txo;
    }
    return @out;
}

sub make_stake_tx {
    my ($reward, $block_sign_data) = @_;
    my @my_txo = grep { txo_confirmed($_) } QBitcoin::TXO->my_utxo();
    my $reward_to = $config->{reward_to} // "union";
    my @out;
    if ($reward_to eq "join" || !@my_txo) {
        @out = make_out_join($reward, \@my_txo);
    }
    elsif ($reward_to eq "separate") {
        @out = make_out_separate($reward, \@my_txo);
    }
    elsif ($reward_to eq "union") {
        @out = make_out_union($reward, \@my_txo);
    }
    elsif ($reward_to eq "none") {
        return undef;
    }
    else {
        Errf("Unknown reward_to %s, disable block validation", $reward_to);
        $config->{reward_to} = "none";
        return undef;
    }

    my $tx = QBitcoin::Transaction->new(
        in              => [ map +{ txo => $_ }, @my_txo ],
        out             => \@out,
        fee             => -$reward,
        tx_type         => TX_TYPE_STAKE,
        block_sign_data => $block_sign_data,
        received_time   => time(),
    );
    $tx->sign_transaction();
    $tx->size = length $tx->serialize;
    return $tx;
}

sub genesis_time() {
    state $genesis_time = $config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME;
    return $genesis_time;
}

sub generate {
    my $class = shift;
    my ($time) = @_;
    my $timeslot = timeslot($time);
    if ($timeslot < genesis_time) {
        die "Genesis time " . genesis_time . " is in future\n";
    }
    my $prev_block;
    my $height = QBitcoin::Block->blockchain_height() // -1;
    if ($height >= 0) {
        $prev_block = QBitcoin::Block->best_block($height)
            or die "No prev block height $height for generate";
        if (timeslot($prev_block->time) >= $timeslot) {
            if ($height == 0) {
                Debugf("Skip regenerating genesis block");
                return;
            }
            $height--;
            $prev_block = QBitcoin::Block->best_block($height)
                or die "No prev block height $height for generate";
            if (timeslot($prev_block->time) >= $timeslot) {
                Warningf("Skip generating blocks from far past, time %s", $time);
                return;
            }
        }
    }
    $height++;
    my $upgraded_total = $prev_block ? $prev_block->upgraded : 0;
    my $upgrade_level = level_by_total($upgraded_total);
    foreach my $coinbase (QBitcoin::Coinbase->get_new($timeslot)) {
        # Create new coinbase transaction and add it to mempool (if it's not there)
        QBitcoin::Transaction->new_coinbase($coinbase, $upgrade_level);
    }
    # Just get upper limit for the stake tx size
    my $stake_tx = make_stake_tx("0e0", "");
    my $size = $stake_tx ? $stake_tx->size : 0;

    my @transactions = QBitcoin::Mempool->choose_for_block($size, $timeslot, $prev_block, $stake_tx && $stake_tx->in);
    if (!@transactions && ($timeslot - genesis_time) / BLOCK_INTERVAL % FORCE_BLOCKS != 0) {
        return;
    }

    my $fee = sum0 map { $_->fee } @transactions;
    my $reward_block = QBitcoin::Block->reward($prev_block, $fee);
    # Block reward if the block will be empty
    my $reward_empty = ($timeslot - genesis_time) % (BLOCK_INTERVAL * FORCE_BLOCKS) ? 0 : $reward_block;
    my $reward = $fee ? $reward_block : $reward_empty;

    if ($reward) {
        $stake_tx or return;
        if (!@{$stake_tx->in}) {
            # Genesis node can validate block with the very first coinbase transaction
            # or create genesis block without validation amount
            if (!$config->{genesis} || QBitcoin::Block->best_weight > 0) {
                return;
            }
        }
        if (UPGRADE_POW && $height == 0 && !$config->{regtest}) {
            # Genesis block should not have coinbase transactions
            @transactions = grep { !$_->is_coinbase } @transactions;
        }
        # Generate new stake_tx with correct output value
        my $block_sign_data = $prev_block ? $prev_block->hash : ZERO_HASH;
        $block_sign_data .= $_->hash foreach @transactions;
        $stake_tx = make_stake_tx($reward, $block_sign_data);
        Infof("Generated stake tx %s with input amount %lu, consume %lu fee", $stake_tx->hash_str,
            sum0(map { $_->{txo}->value } @{$stake_tx->in}), -$stake_tx->fee);
        # It's possible that the $stake_tx has no my_txo, so it may be not unique, already received or pending
        # Ignore if already received; process if pending
        if (QBitcoin::Transaction->check_by_hash($stake_tx->hash)) {
            Warningf("Generated stake tx %s already known, skip block generation", $stake_tx->hash_str);
            return;
        }
        $_->{txo}->spent_add($stake_tx) foreach @{$stake_tx->in};
        QBitcoin::TXO->save_all($stake_tx->hash, $stake_tx->out);
        $stake_tx->validate() == 0
            or die "Incorrect generated stake transaction\n";
        $stake_tx->save() == 0
            or die "Can't save stake transaction\n";
        $stake_tx->process_pending();
        if (defined(my $height = QBitcoin::Block->recv_pending_tx($stake_tx))) {
            Infof("Generated stake tx %s is pending by a block, process it and skip new block generation", $stake_tx->hash_str);
            if ($height != -1) {
                my $block = QBitcoin::Block->best_block($height);
                if (my $connection = $block->received_from) {
                    $connection->syncing(0);
                    $connection->request_new_block();
                }
                return;
            }
        }
        unshift @transactions, $stake_tx;
    }
    my $generated = QBitcoin::Block->new({
        height       => $height,
        time         => $timeslot,
        prev_hash    => $prev_block ? $prev_block->hash : undef,
        transactions => \@transactions,
        $prev_block ? ( prev_block => $prev_block ) : (),
    });
    $generated->weight = $generated->self_weight + ( $prev_block ? $prev_block->weight : 0 );
    $generated->merkle_root = $generated->calculate_merkle_root();
    $generated->hash = $generated->calculate_hash();
    $generated->add_tx($_) foreach @transactions;
    QBitcoin::Generate::Control->generated_time($time);
    Debugf("Generated block %s height %u weight %Lu, %u transactions",
        $generated->hash_str, $height, $generated->weight, scalar(@transactions));
    if ($generated->receive()) {
        die "Generated block " . $generated->hash_str . " is invalid\n";
    }
    return $generated;
}

1;
