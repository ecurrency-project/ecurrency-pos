#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Const;
use QBitcoin::Test::ORM;
use QBitcoin::Config;
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Utils qw(check_tx_tokens_balance);

$config->{regtest} = 1;

my $token_a    = "\xaa" x 32;
my $token_b    = "\xbb" x 32;
my $scripthash = "\x11" x 20;

sub transfer_data {
    my ($amount) = @_;
    return TOKEN_TXO_TYPE_TRANSFER . pack("Q<", $amount);
}

# Input txo as produced by deserialize/load: token txos have token_hash and token data,
# plain QBTC txos have no token_hash and empty data
my $tx_in_num = 0;
sub in_txo {
    my ($token_hash, $data, $value) = @_;
    my $txo = QBitcoin::TXO->new_txo({
        tx_in      => pack("C", $tx_in_num++) x 32,
        num        => 0,
        value      => $value // 0,
        scripthash => $scripthash,
        data       => $data // "",
    });
    $txo->token_hash = $token_hash if defined $token_hash;
    return $txo;
}

# Output txo as built by create_txo in wallet_tx_create: no token_hash set
sub out_txo {
    my ($data, $value) = @_;
    return QBitcoin::TXO->new_txo({
        value      => $value // 0,
        scripthash => $scripthash,
        data       => $data // "",
    });
}

sub make_tx {
    my ($token_hash, $in, $out) = @_;
    my $num = 0;
    $_->num = $num++ foreach @$out;
    return QBitcoin::Transaction->new(
        in      => [ map +{ txo => $_, siglist => [] }, @$in ],
        out     => $out,
        fee     => 0,
        tx_type => defined($token_hash) ? TX_TYPE_TOKENS : TX_TYPE_STANDARD,
        defined($token_hash) ? ( token_hash => $token_hash ) : (),
    );
}

# Correct tokens transaction: QBTC fee input and QBTC change output must not affect the check
my $tx_ok = make_tx($token_a,
    [ in_txo($token_a, transfer_data(1000)), in_txo(undef, "", 500) ],
    [ out_txo(transfer_data(600)), out_txo(transfer_data(400)), out_txo("", 400) ],
);
is(check_tx_tokens_balance($tx_ok), undef, "Correct tokens transaction passes");

# Spend tokens with another token_id
my $err_wrong_token = check_tx_tokens_balance(make_tx($token_a,
    [ in_txo($token_a, transfer_data(1000)), in_txo($token_b, transfer_data(1000)) ],
    [ out_txo(transfer_data(2000)) ],
));
like($err_wrong_token, qr/burns tokens/, "Spend tokens with another token_id rejected");

# Outputs less than inputs (burn)
my $err_burn = check_tx_tokens_balance(make_tx($token_a,
    [ in_txo($token_a, transfer_data(1000)) ],
    [ out_txo(transfer_data(700)) ],
));
like($err_burn, qr/Burn tokens not allowed/, "Outputs less than inputs rejected");

# Spend tokens in standard transaction
my $err_standard = check_tx_tokens_balance(make_tx(undef,
    [ in_txo($token_a, transfer_data(1000)) ],
    [ out_txo("", 100) ],
));
like($err_standard, qr/burns tokens/, "Spend tokens in standard transaction rejected");

# Outputs more than inputs without mint permission
my $err_mint = check_tx_tokens_balance(make_tx($token_a,
    [ in_txo($token_a, transfer_data(1000)) ],
    [ out_txo(transfer_data(1500)) ],
));
like($err_mint, qr/mint tokens without permission/, "Mint without permission rejected");

# Outputs more than inputs with mint permission
my $mint_data = TOKEN_TXO_TYPE_PERMISSIONS . pack("C", TOKEN_PERMISSION_MINT);
my $tx_mint_ok = make_tx($token_a,
    [ in_txo($token_a, transfer_data(1000)), in_txo($token_a, $mint_data) ],
    [ out_txo(transfer_data(1500)), out_txo($mint_data) ],
);
is(check_tx_tokens_balance($tx_mint_ok), undef, "Mint with permission passes");

# Gain permission without permission input
my $err_permission = check_tx_tokens_balance(make_tx($token_a,
    [ in_txo($token_a, transfer_data(1000)) ],
    [ out_txo(transfer_data(1000)), out_txo($mint_data) ],
));
like($err_permission, qr/gain token permission/, "Gain permission without permission rejected");

done_testing();
