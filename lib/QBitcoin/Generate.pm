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
use QBitcoin::MyAddress qw(my_address stake_address);
use QBitcoin::Transaction;
use QBitcoin::Crypto qw(hash256);
use QBitcoin::Slashing;
use QBitcoin::ValueUpgraded qw(level_by_total);
use QBitcoin::Utils qw(get_address_utxo);
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
    my $count = 0;
    my $value = 0;
    my $scripthash = $my_address->scripthash;
    my $chain_utxo = get_address_utxo($my_address->address, 1000);
    foreach my $txid (keys %$chain_utxo) {
        for (my $vout = @{$chain_utxo->{$txid}}-1; $vout >= 0; $vout--) {
            next unless defined $chain_utxo->{$txid}->[$vout];
            my $utxo = QBitcoin::TXO->new_saved({
                tx_in      => $txid,
                num        => $vout,
                value      => $chain_utxo->{$txid}->[$vout]->{value},
                scripthash => $scripthash,
                data       => $chain_utxo->{$txid}->[$vout]->{data} // "",
            });
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
            foreach my $addr (stake_address()) {
                if (grep { $_ eq $sign_alg } $addr->algo) {
                    $my_address = $addr;
                    last;
                }
            }
            last if $my_address;
        }
    }
    $my_address //= (stake_address())[0]
        or return ();
    my $my_amount = sum0 map { $_->value } @$my_txo;
    my $out = QBitcoin::TXO->new_txo(
        value      => $my_amount + $reward,
        scripthash => scalar($my_address->scripthash),
    );
    return $out;
}

sub my_txo_by_address {
    my ($my_txo, $timeslot) = @_;
    if (@$my_txo == 1) {
        # The most common case, only one my_txo
        # Weight is not important here, so use 1
        return [ $my_txo->[0]->scripthash, $my_txo->[0]->value, 1 ];
    }
    my $time = $timeslot // timeslot(time());
    my %my;
    foreach my $my_txo (@$my_txo) {
        my $my = $my{$my_txo->scripthash} //= [ 0, 0 ];
        $my->[0] += $my_txo->value;
        $my->[1] += $my_txo->value * ($time - QBitcoin::Transaction->txo_time($my_txo));
    }
    return (
        sort { $b->[2] <=> $a->[2] || $b->[1] <=> $a->[1] || $a->[0] cmp $b->[0] }
            map { [ $_, $my{$_}->[0], $my{$_}->[1] ] }
                keys %my
    );
}

sub make_out_separate {
    my ($reward, $my_txo, $timeslot) = @_;
    @$my_txo or return make_out_join($reward, $my_txo);
    my ($my_best) = my_txo_by_address($my_txo, $timeslot);
    @$my_txo = grep { $_->scripthash eq $my_best->[0] } @$my_txo;
    return QBitcoin::TXO->new_txo(
        value      => $my_best->[1] + $reward,
        scripthash => $my_best->[0],
    );
}

sub make_out_union {
    my ($reward, $my_txo, $timeslot) = @_;
    my @my;
    if (!@$my_txo) {
        # Reward to all stake addresses in equal parts
        @my = map { [ scalar($_->scripthash), 0, 1 ] } stake_address();
    }
    else {
        @my = my_txo_by_address($my_txo, $timeslot);
    }
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
    my ($reward, $block_sign_data, $timeslot) = @_;
    my @my_txo = grep { txo_confirmed($_) } QBitcoin::TXO->staked_utxo();
    my $reward_to = $config->{reward_to} // "union";
    my @out;
    if ($reward_to eq "join") {
        @out = make_out_join($reward, \@my_txo);
    }
    elsif ($reward_to eq "separate") {
        @out = make_out_separate($reward, \@my_txo, $timeslot);
    }
    elsif ($reward_to eq "union") {
        @out = make_out_union($reward, \@my_txo, $timeslot);
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
    # A best-branch switch may have filled a slot that was empty before the current
    # timeslot with a block received from a peer (a weak validator can grab the smoothed
    # reward this way). Try once to generate our own block for that slot and height; if our
    # stake yields a heavier branch it switches over on weight, then we fall through and
    # build the block for the current timeslot on top of it.
    if (defined(my $level = QBitcoin::Generate::Control->generate_level)) {
        QBitcoin::Generate::Control->generate_level(undef); # one contest attempt per filled slot
        # When the filled slot is a past one, contest_level builds a block there and we fall
        # through to build the current-slot block on top. When it is the current slot,
        # contest_level builds our competing block directly in it (there is no separate top
        # block to add) and returns true so we stop here.
        return if $class->contest_level($level, $timeslot);
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
            if ($prev_block->next_block) {
                Infof("Skip generating block on too low height %u time %s", $height + 1, $time);
                return;
            }
            # If current best block is our with the same height than unconfirm it for use the same stake amount
            if (!$prev_block->received_from) {
                # Slashing self-guard: if we already published a stake for this slot, our
                # own block already occupies it. Regenerating would re-sign the same
                # (slot, UTXO) into a different block => self-equivocation. Keep it as is.
                if (QBitcoin::Generate::Control->staked_slot($timeslot)) {
                    Debugf("Keep our published block %s height %u for slot %u, skip regeneration (slashing self-guard)",
                        $prev_block->hash_str, $height, $timeslot);
                    return;
                }
                Debugf("Unconfirming our block %s height %u for regenerating", $prev_block->hash_str, $height);
                $prev_block->unconfirm();
            }
            # The tip is a peer block whose stake is equivocated and we hold a slashing tx
            # for it: unconfirm it so the rebuilt block (on its parent, in this timeslot,
            # using the mempool) can include the slashing tx - its slashed UTXO is then
            # free. Skip if we already staked this slot (would self-equivocate); the
            # slashing tx stays in the mempool and we retry next slot.
            elsif (!QBitcoin::Generate::Control->staked_slot($timeslot)
                   && QBitcoin::Slashing->tip_slashing($prev_block)) {
                Debugf("Unconfirming peer tip %s height %u to slash its equivocated stake",
                    $prev_block->hash_str, $height);
                $prev_block->unconfirm();
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
    return $class->_generate($timeslot, $height, $prev_block);
}

# Try to generate our own block at the given height to contest a block that filled a slot
# which was effectively empty in our branch (no block, or only an empty/forced one that
# carried no stake). The contested block and its parent are taken from the current best
# branch. The block is built reusing only the contested branch's transactions (the $contest
# flag), not the mempool, so a fee-paying tx the contested branch consumed in that slot is
# available to us too - without it reward would be 0 and we could not stake at all. If the
# result is not a heavier branch, _generate() drops it.
#
# Returns true if it built our block in the CURRENT slot (so generate() must not also build
# a current-slot block on top), false otherwise (a past slot - generate() falls through and
# builds the current-slot block on top of the contested branch).
sub contest_level {
    my $class = shift;
    my ($level, $timeslot) = @_;
    $level >= 1
        or return 0; # genesis has no slot to contest
    my $contested = QBitcoin::Block->best_block($level)
        or return 0;
    my $prev_block = QBitcoin::Block->best_block($level - 1)
        or return 0;
    # Only contest a block received from a peer; our own block we would simply regenerate.
    $contested->received_from
        or return 0;
    my $contested_slot = timeslot($contested->time);
    if ($contested_slot < $timeslot) {
        # Past slot: generate in the latest past slot (the previous one), not the contested
        # block's own slot - a later slot gives our stake more weight and a better chance to
        # outweigh the branch. But cap it at the last slot of $prev_block's forced-block
        # window: a slot beyond that boundary would skip a forced block and make our block
        # invalid ("Forced block missed", see QBitcoin::Block::Validate). The mempool stays
        # free (we pass the $contest flag) for the current-timeslot block generate() builds on
        # top after we return; otherwise our branch could end up without a current-slot block
        # while the contested branch gets one and so weighs more.
        my $genesis = genesis_time();
        my $max_slot = $genesis +
            (int(($prev_block->time - $genesis) / BLOCK_INTERVAL / FORCE_BLOCKS) + 1) * FORCE_BLOCKS * BLOCK_INTERVAL;
        my $build_slot = $timeslot - BLOCK_INTERVAL;
        $build_slot = $max_slot if $build_slot > $max_slot;
        Debugf("Contest block %s height %u from past slot %u, build at slot %u",
            $contested->hash_str, $level, $contested_slot, $build_slot);
        $class->_generate($build_slot, $level, $prev_block, 1);
        return 0; # fall through in generate() to build the current-slot block on top
    }
    # Current slot: the contested peer block occupies the current slot at our tip height. The
    # normal generation path cannot beat it - it would build on top of the contested block,
    # and that branch already consumed the slot's fee tx, so our block there would be
    # stakeless (reward 0) with weight +1. Build our competing block in the current slot at
    # the contested height instead, reusing the contested branch's transactions so the fee
    # tx is available and our stake applies. If it outweighs the contested block it switches
    # over and becomes the tip; we are already in the current slot, so no block on top.
    Debugf("Contest block %s height %u in current slot %u", $contested->hash_str, $level, $contested_slot);
    $class->_generate($timeslot, $level, $prev_block, 1);
    return 1; # we hold the current slot; generate() must not build another block on top
}

sub _generate {
    my $class = shift;
    my ($timeslot, $height, $prev_block, $contest) = @_;
    my $upgraded_total = $prev_block ? $prev_block->upgraded : 0;
    my $upgrade_level = level_by_total($upgraded_total);
    foreach my $coinbase (QBitcoin::Coinbase->get_new($timeslot)) {
        # Create new coinbase transaction and add it to mempool (if it's not there)
        QBitcoin::Transaction->new_coinbase($coinbase, $upgrade_level);
    }
    # Just get upper limit for the stake tx size
    my $stake_tx = make_stake_tx("0e0", "", $timeslot);
    my $size = $stake_tx ? $stake_tx->size : 0;

    my @transactions = QBitcoin::Mempool->choose_for_block($size, $timeslot, $prev_block, $stake_tx && $stake_tx->in, $contest);
    if (!@transactions && ($timeslot - genesis_time) / BLOCK_INTERVAL % FORCE_BLOCKS != 0) {
        return;
    }

    my $fee = sum0 map { $_->fee } @transactions;
    my $reward_block = QBitcoin::Block->reward($prev_block, $fee, $timeslot);
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
            my $genesis_coinbase = $config->{testnet} ? GENESIS_COINBASE_TESTNET : GENESIS_COINBASE;
            if ($genesis_coinbase) {
                return unless btc_synced();
                my $coinbase_value = sum0 map { $_->up->value } grep { $_->is_coinbase } @transactions;
                next unless $coinbase_value >= $genesis_coinbase;
            }
            else {
                @transactions = grep { !$_->is_coinbase } @transactions;
            }
        }
        # Generate new stake_tx with correct output value. Must match Block::sign_data:
        # prev_hash . timeslot . hash256(concat of non-stake tx hashes). @transactions
        # here holds exactly the non-stake txs (the stake is unshifted to index 0 below).
        my $tx_hashes = "";
        $tx_hashes .= $_->hash foreach @transactions;
        my $block_sign_data = ($prev_block ? $prev_block->hash : ZERO_HASH) . pack("N", $timeslot) . hash256($tx_hashes);
        $stake_tx = make_stake_tx($reward, $block_sign_data, $timeslot);
        Infof("Generated stake tx %s with input amount %lu, consume %lu fee", $stake_tx->hash_str,
            sum0(map { $_->{txo}->value } @{$stake_tx->in}), -$stake_tx->fee);
        # Slashing self-guard (skip genesis / inputless stake): never (re)stake the
        # startup slot or earlier, and never publish a second, different stake for a
        # (slot, UTXO) we already committed - that would be self-equivocation.
        if ($prev_block && @{$stake_tx->in}) {
            if (!QBitcoin::Generate::Control->may_stake_slot($timeslot)) {
                Debugf("Skip stake for slot %u: at or before the startup slot %u",
                    $timeslot, QBitcoin::Generate::Control->start_slot // -1);
                return;
            }
            if (QBitcoin::Generate::Control->stake_conflicts($timeslot, $stake_tx)) {
                Warningf("Skip generating block: stake %s would equivocate an already-published stake for slot %u",
                    $stake_tx->hash_str, $timeslot);
                return;
            }
        }
        # It's possible that the $stake_tx has no my_txo, so it may be not unique, already received or pending
        # Ignore if already received or pending (pending means its output TXO is already in %TXO cache)
        if (QBitcoin::Transaction->check_by_hash($stake_tx->hash) ||
            QBitcoin::Transaction->has_pending($stake_tx->hash)) {
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
    QBitcoin::Generate::Control->generated_time($timeslot);
    Debugf("Generated block %s height %u weight %Lu, %u transactions",
        $generated->hash_str, $height, $generated->weight, scalar(@transactions));
    if ($generated->receive()) {
        die "Generated block " . $generated->hash_str . " is invalid\n";
    }
    # Remove the block from cache (and free my utxo) if it was not added as best block
    if (QBitcoin::Block->best_block->hash ne $generated->hash) {
        $generated->free();
    }
    elsif (@{$generated->transactions} && $generated->transactions->[0]->is_stake
           && @{$generated->transactions->[0]->in}) {
        # Our block entered the best branch, so its stake signature may reach peers:
        # record it so we never sign a conflicting stake for the same (slot, UTXO).
        QBitcoin::Generate::Control->record_stake($timeslot, $generated->transactions->[0]);
    }
    return $generated;
}

1;
