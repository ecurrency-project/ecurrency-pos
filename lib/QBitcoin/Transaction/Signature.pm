package QBitcoin::Transaction::Signature;
use warnings;
use strict;

use QBitcoin::MyAddress;
use QBitcoin::Delegation;
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::BlockchainParams;
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::Delegation qw(SELECTOR_OWNER SELECTOR_DELEGATE);
use QBitcoin::Crypto qw(signature);
use QBitcoin::RedeemScript;
use Role::Tiny;

# useful links:
# https://bitcoin.stackexchange.com/questions/3374/how-to-redeem-a-basic-tx
# https://en.bitcoin.it/w/images/en/7/70/Bitcoin_OpCheckSig_InDetail.png
# https://developer.bitcoin.org/devguide/transactions.html
# https://gist.github.com/Sjors/5574485 (ruby)

sub sign_transaction {
    my $self = shift;
    foreach my $num (0 .. $#{$self->in}) {
        my $in = $self->in->[$num];
        my $scripthash = $in->{txo}->scripthash;
        my $delegation;
        if ($self->tx_type == TX_TYPE_STAKE && ($delegation = QBitcoin::Delegation->get_by_hash($scripthash))) {
            # An address delegated to this node: sign the stake branch of the
            # covenant with the staking key (the owner key is not ours)
            $self->make_delegation_sign($in, $delegation, $num);
        }
        elsif (my $address = QBitcoin::MyAddress->get_by_hash($scripthash, 0)) {
            $self->make_sign($in, $address, $num);
        }
        else {
            Errf("Can't sign transaction: address for %s:%u is not my, scripthash %s",
                $in->{txo}->tx_in_str, $in->{txo}->num, unpack("H*", $scripthash));
        }
    }
    $self->calculate_hash;
}

sub make_sign {
    my $self = shift;
    my ($in, $address, $input_num) = @_;

    my $redeem_script = $address->script_by_hash($in->{txo}->scripthash)
        or die "Can't get redeem script by hash " . unpack("H*", $in->{txo}->scripthash);
    my @pk_alg = $address->algo;
    my $sign_alg;
    if ($config->{sign_alg}) {
        my %pk_alg = map { $_ => 1 } @pk_alg;
        ($sign_alg) = grep { $pk_alg{$_} } split(/\s+/, $config->{sign_alg});
        $sign_alg //= $pk_alg[0];
    }
    else {
        $sign_alg = $pk_alg[0];
    }
    my $sighash_type = SIGHASH_ALL;
    my $sign_data;
    if (time() < SIGN_TOKEN_HASH_START - BLOCK_INTERVAL*FORCE_BLOCKS && $self->is_tokens) {
        $sign_data = $self->sign_data_legacy($input_num, $sighash_type);
        $self->legacy_signature(1);
    }
    else {
        $sign_data = $self->sign_data($input_num, $sighash_type);
    }
    $sign_data
        or die "Can't get sign data for input $input_num";
    my $signature = signature($sign_data, $address, $sign_alg, $sighash_type);
    $in->{txo}->set_redeem_script($redeem_script);
    my $script_type = QBitcoin::RedeemScript->script_type($redeem_script);
    if ($script_type eq "P2PKH") {
        $in->{siglist} = [ $signature, $address->pubkey ];
    }
    elsif ($script_type eq "P2PK") {
        $in->{siglist} = [ $signature ];
    }
    elsif ($script_type eq "DELEGATION") {
        # A delegated-staking address whose owner key is in this wallet
        $in->{siglist} = [ $signature, $address->pubkey, SELECTOR_OWNER ];
    }
}

sub make_delegation_sign {
    my $self = shift;
    my ($in, $delegation, $input_num) = @_;

    my $staking_key = $delegation->staking_key;
    my $sighash_type = SIGHASH_ALL;
    my $sign_data = $self->sign_data($input_num, $sighash_type)
        or die "Can't get sign data for input $input_num";
    my $signature = signature($sign_data, $staking_key, $staking_key->algo, $sighash_type);
    $in->{txo}->set_redeem_script($delegation->redeem_script);
    $in->{siglist} = [ $signature, $staking_key->pubkey, SELECTOR_DELEGATE ];
}

1;
