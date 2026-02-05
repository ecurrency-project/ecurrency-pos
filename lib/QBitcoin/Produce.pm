package QBitcoin::Produce;
use warnings;
use strict;
use feature 'state';

# This module is for testing only!
# It generates random coinbase transactions (without inputs) and other mempool transactions

use List::Util qw(sum shuffle);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::RedeemScript;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Crypto qw(hash160 checksum32);
use QBitcoin::Address qw(scripthash_by_address);
use QBitcoin::MyAddress qw(stake_address);

use constant {
    MAX_MY_UTXO  => 8,
    MY_UTXO_PROB => 10 * BLOCK_INTERVAL, # probability 1/2 for generating 1 utxo per 10 blocks
    TX_FEE_PROB  =>  2 * BLOCK_INTERVAL, # probability 1/2 for generating 1 tx with fee >0 per 2 blocks
    TX_ZERO_PROB => 20 * BLOCK_INTERVAL, # probability 1/2 for generating 1 tx with 0 fee per 20 blocks
    MY_UPGRADE   => 1000, # each 1000th bitcoin txo considering as upgrade my address
    UPGRADE_PROB => 1000, # each 1000th bitcoin txo considering as upgrade
    FEE_MY_TX    => 0.1,
};

sub probability {
    my ($period, $half_period) = @_;
    # If $period == $half, probability is 1/2
    return $period > $half_period ? 1 - 1 / 2**($period / $half_period) : $period / $half_period / 2;
}

sub produce {
    my $class = shift;
    my $time = time();
    state $prev_run = $time;
    return if $prev_run >= $time;
    my $period = ($time - $prev_run);
    $prev_run = $time;

    if (QBitcoin::TXO->staked_utxo() < MAX_MY_UTXO && !UPGRADE_POW) {
        my $prob = probability($period, MY_UTXO_PROB);
        _produce_my_utxo() if $prob > rand();
    }
    {
        my $prob = probability($period, TX_FEE_PROB);
        _produce_tx(0.03) if $prob > rand();
    }
    {
        my $prob = probability($period, TX_ZERO_PROB);
        _produce_tx(0) if $prob > rand();
    }
}

sub produce_coinbase {
    my $class = shift;
    my ($tx, $num) = @_;

    my $out = $tx->out->[$num];
    # Do not use rand() for get this upgrade deterministic and verifiable
    my $rnd = unpack("V", checksum32($tx->hash . $num));
    # We should not generate coinbase for my address on different nodes for the same btc txo, so xor $rnd with hash of my address
    my ($my_address) = stake_address()
        or return undef;
    state $myaddr_hash = unpack("V", checksum32($my_address->address));
    if ($rnd < 0x10000 * 0x10000 / UPGRADE_PROB) {
        $out->{open_script} = QBT_LOCK_SCRIPT;
        $tx->out->[$num+1] = {
            value       => 0,
            open_script => "\x14" . hash160(OP_VERIFY),
        };
        Infof("Produce coinbase with open txo: tx %s value %Lu", $tx->hash_str, $tx->out->[$num]->{value});
        return 1;
    }
    elsif (QBitcoin::TXO->staked_utxo() < MAX_MY_UTXO &&
           ($rnd ^ $myaddr_hash) < 0x10000 * 0x10000 / MY_UPGRADE) {
        state $my_scripthash = scripthash_by_address($my_address->address);
        $out->{open_script} = QBT_LOCK_SCRIPT;
        $tx->out->[$num+1] = {
            value       => 0,
            open_script => pack("C", length($my_scripthash)) . $my_scripthash,
        };
        Infof("Produce coinbase for my address: tx %s value %Lu", $tx->hash_str, $tx->out->[$num]->{value});
        return 1;
    }
    return undef;
}

sub _produce_my_utxo {
    my ($my_address) = stake_address() # first one
        or return;
    state $last_time = 0;
    my $time = time();
    my $age = int($time - ($config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME));
    $last_time = $last_time < $age ? $age : $last_time+1;
    my $out = QBitcoin::TXO->new_txo(
        value      => $last_time, # vary for get unique hash for each coinbase transaction
        scripthash => scalar(scripthash_by_address($my_address->address)),
    );
    my $tx = QBitcoin::Transaction->new(
        in            => [],
        out           => [ $out ],
        fee           => 0,
        tx_type       => TX_TYPE_COINBASE,
        coins_created => $out->{value},
        received_time => $time,
    );
    $tx->sign_transaction();
    QBitcoin::TXO->save_all($tx->hash, $tx->out);
    $tx->size = length $tx->serialize;
    if ($tx->validate() != 0) {
        Errf("Produced incorrect coinbase transaction");
        return;
    }
    $tx->save();
    Noticef("Produced coinbase transaction %s", $tx->hash_str);
    $tx->announce();
    return $tx;
}

sub _produce_tx {
    my ($fee_part) = @_;

    my $redeem_script = OP_VERIFY;
    state $script;
    if (!$script) {
        ($script) = QBitcoin::RedeemScript->find(hash => hash160($redeem_script));
        if (!$script) {
            Debugf("No free txo script, produce transaction skipped");
            return undef;
        }
    }
    my @txo = QBitcoin::TXO->find(tx_out => undef, scripthash => $script->id, -limit => 100);
    # Exclude loaded txo to avoid double-spend
    # b/c its may be included as input into another mempool transaction
    @txo = grep { !$_->is_cached } @txo;
    if (!@txo) {
        Debugf("No free txo, produce transaction skipped");
        return undef;
    }

    @txo = shuffle @txo;
    @txo = splice(@txo, 0, 2);
    $_->save foreach grep { !$_->is_cached } @txo;
    $_->set_redeem_script($redeem_script) foreach @txo;
    my $amount = sum map { $_->value } @txo;
    my $fee = int($amount * $fee_part);
    my $siglist = [ "\x01", "\x01" ];
    my $out = QBitcoin::TXO->new_txo(
        value      => $amount - $fee,
        scripthash => hash160($redeem_script),
    );
    my $tx = QBitcoin::Transaction->new(
        in            => [ map +{ txo => $_, siglist => $siglist }, @txo ],
        out           => [ $out ],
        fee           => $fee,
        tx_type       => TX_TYPE_STANDARD,
        received_time => time(),
        @txo ? () : ( coins_created => $amount ),
    );
    $tx->calculate_hash;
    if (QBitcoin::Transaction->check_by_hash($tx->hash)) {
        Infof("Just produced transaction %s already exists", $tx->hash_str);
        return undef;
    }
    QBitcoin::TXO->save_all($tx->hash, $tx->out);
    $_->del_my_utxo() foreach grep { $_->is_my } @txo;
    if ($tx->validate() != 0) {
        Errf("Produced incorrect transaction");
        die "Produced incorrect transaction\n";
    }
    $tx->save();
    Noticef("Produced transaction %s with fee %i", $tx->hash_str, $tx->fee);
    Debugf("Produced transaction inputs:");
    Debugf("  tx_in: %s, num: %u", $_->tx_in_str, $_->num) foreach @txo;
    $tx->announce();
    return $tx;
}

1;
