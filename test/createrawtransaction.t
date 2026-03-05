#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::Address qw(address_by_hash);
use Bitcoin::Address qw(encode_btc_address encode_p2wpkh encode_p2tr);
use QBitcoin::TXO;
use QBitcoin::Transaction;
use Bitcoin::Serialized;

$config->{debug} = 0;
$config->{regtest} = 1;

# Mock _load_token_info so that decoding token outputs does not try to load
# the token contract transaction from the (empty test) database.
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('_load_token_info', sub { return {} });
$transaction_module->mock('validate_coinbase', sub { return 0 });

# -----------------------------------------------------------------------
# Minimal RPC handler for testing cmd_createrawtransaction /
# cmd_decoderawtransaction without the HTTP layer.
# -----------------------------------------------------------------------
{
    package TestRPC;
    use warnings;
    use strict;
    use QBitcoin::Accessors qw(mk_accessors);
    use Role::Tiny::With;
    with 'QBitcoin::RPC::Commands';
    mk_accessors(qw(cmd args validate_message _rpc_result _rpc_error));
    sub new { bless {}, shift }
    sub response_ok    { $_[0]->_rpc_result($_[1]); 0 }
    sub response_error { $_[0]->_rpc_error($_[2] // $_[1]); -1 }
}

# Helper: call createrawtransaction with given inputs/outputs arrays.
# Returns the hex string, or undef on error.
sub create_raw_tx {
    my ($inputs, $outputs) = @_;
    my $rpc = TestRPC->new;
    $rpc->args([$inputs, $outputs]);
    $rpc->cmd('createrawtransaction');
    $rpc->cmd_createrawtransaction;
    return $rpc->_rpc_result;
}

# Helper: call decoderawtransaction with a hex string.
# Returns the decoded hashref, or undef on error.
sub decode_raw_tx {
    my ($hex) = @_;
    my $rpc = TestRPC->new;
    $rpc->args([$hex]);
    $rpc->cmd('decoderawtransaction');
    $rpc->cmd_decoderawtransaction;
    return $rpc->_rpc_result;
}

# -----------------------------------------------------------------------
# Test addresses
# -----------------------------------------------------------------------
# Generate a valid QBTC address from an arbitrary script hash.
my $test_scripthash = hash160("test-redeem-script");
my $test_qbtc_addr  = address_by_hash($test_scripthash);

# Generate valid Bitcoin addresses of each standard type.
my $btc_hash160 = "a" x 20;   # 20 arbitrary bytes (0xaa each)
my $btc_p2pkh_addr  = encode_btc_address("\x00", $btc_hash160);   # P2PKH mainnet
my $btc_p2sh_addr   = encode_btc_address("\x05", "b" x 20);       # P2SH  mainnet
my $btc_p2wpkh_addr = encode_p2wpkh("c" x 20);                    # P2WPKH Bech32
my $btc_p2tr_addr   = encode_p2tr("d" x 32);                      # P2TR   Bech32m

# Keep the old name pointing at P2PKH for the existing test 2.
my $btc_addr = $btc_p2pkh_addr;

# A fake 64-character hex txid (all-zeros placeholder for unsigned tx inputs).
my $fake_txid = "00" x 32;

# -----------------------------------------------------------------------
# 1. Normal QBTC output
# -----------------------------------------------------------------------
{
    my $hex = create_raw_tx(
        [ { txid => $fake_txid, vout => 0 } ],
        [ { $test_qbtc_addr => 1.0 } ],
    );
    ok(defined($hex) && length($hex), "createrawtransaction (normal): produces hex");

    my $decoded = decode_raw_tx($hex);
    ok($decoded, "decoderawtransaction (normal): decodes successfully");
    is($decoded->{type}, "standard", "normal tx type is 'standard'");
    is(scalar @{$decoded->{out}}, 1, "normal tx: one output");
    is($decoded->{out}[0]{address}, $test_qbtc_addr,
        "normal output: QBTC address is preserved");
    cmp_ok($decoded->{out}[0]{value}, '==', 1.0,
        "normal output: value is 1.0 QBTC");
    is($decoded->{out}[0]{data}, "",
        "normal output: data field is empty");
}

# -----------------------------------------------------------------------
# 2. Bitcoin P2PKH downgrade output
#    Passing a Bitcoin address should create a TXO to the freeze1 address
#    with the BTC address string stored in the data field.
#    decoderawtransaction must show the Bitcoin address back.
# -----------------------------------------------------------------------
{
    my $hex = create_raw_tx(
        [ { txid => $fake_txid, vout => 0 } ],
        [ { $btc_addr => 1.0 } ],
    );
    ok(defined($hex) && length($hex),
        "createrawtransaction (bitcoin-downgrade): produces hex");

    my $decoded = decode_raw_tx($hex);
    ok($decoded, "decoderawtransaction (bitcoin-downgrade): decodes successfully");
    is($decoded->{type}, "standard",
        "bitcoin-downgrade tx type is 'standard'");
    is(scalar @{$decoded->{out}}, 1,
        "bitcoin-downgrade tx: one output");
    is($decoded->{out}[0]{address}, $btc_addr,
        "bitcoin-downgrade output: Bitcoin address is shown (not freeze1)");
    ok(!exists $decoded->{out}[0]{data},
        "bitcoin-downgrade output: no 'data' field (consumed by address decoding)");
    cmp_ok($decoded->{out}[0]{value}, '==', 1.0,
        "bitcoin-downgrade output: value is 1.0 QBTC");
}

# -----------------------------------------------------------------------
# 3. Token output
#    createrawtransaction with token_id + token_amount should build a
#    TX_TYPE_TOKENS transaction.  decoderawtransaction must reflect the
#    token_id and token_amount.
# -----------------------------------------------------------------------
{
    my $token_hash_hex = "11" x 32;   # 64 hex chars — the token contract txid
    my $token_amount   = 1000;

    my $hex = create_raw_tx(
        [ { txid => $fake_txid, vout => 0 } ],
        [ {
            $test_qbtc_addr => 0,
            token_id        => $token_hash_hex,
            token_amount    => $token_amount,
        } ],
    );
    ok(defined($hex) && length($hex),
        "createrawtransaction (token): produces hex");

    my $decoded = decode_raw_tx($hex);
    ok($decoded, "decoderawtransaction (token): decodes successfully");
    is($decoded->{type}, "tokens",
        "token tx type is 'tokens'");
    is($decoded->{token_id}, $token_hash_hex,
        "token tx-level token_id is correct");
    is(scalar @{$decoded->{out}}, 1,
        "token tx: one output");
    is($decoded->{out}[0]{token_id}, $token_hash_hex,
        "token output: token_id is correct");
    is($decoded->{out}[0]{token_amount}, $token_amount,
        "token output: token_amount is correct");
}

# -----------------------------------------------------------------------
# 4. Freeze1 input restriction
#    A non-burn transaction that spends a freeze1 UTXO must be rejected
#    by Transaction->validate().  A burn transaction must NOT be rejected
#    by that specific check.
# -----------------------------------------------------------------------
{
    # Build a freeze1 TXO (output locked to QBT_BURN_SCRIPT / QBT_BURN_SCRIPTHASH).
    my $freeze1_txo = QBitcoin::TXO->new_txo(
        tx_in         => "\x01" x 32,    # fake source tx hash (32 bytes)
        num           => 0,
        scripthash    => hash160(QBT_BURN_SCRIPT),
        value         => 1 * DENOMINATOR,
        redeem_script => QBT_BURN_SCRIPT,
    );

    # An ordinary output for the destination in the bad tx.
    my $out_txo = QBitcoin::TXO->new_txo(
        scripthash => $test_scripthash,
        value      => 1 * DENOMINATOR,
        num        => 0,
    );

    # Standard (non-burn) transaction spending the freeze1 UTXO — must fail.
    my $bad_tx = QBitcoin::Transaction->new(
        in      => [ { txo => $freeze1_txo, siglist => [] } ],
        out     => [ $out_txo ],
        tx_type => TX_TYPE_STANDARD,
        fee     => 0,
    );
    $bad_tx->calculate_hash;
    $out_txo->{tx_in} = $bad_tx->hash;

    is($bad_tx->validate, -1,
        "standard tx spending freeze1 UTXO is rejected by validate()");

    # Burn transaction spending the freeze1 UTXO — the freeze1 guard must
    # NOT fire (the is_burn branch handles it).  To isolate this check from
    # unrelated failures (e.g. signature verification with an empty siglist),
    # mock check_input_script to succeed.
    $transaction_module->mock('check_input_script', sub { 0 });

    my $burn_tx = QBitcoin::Transaction->new(
        in      => [ { txo => $freeze1_txo, siglist => [] } ],
        out     => [],
        tx_type => TX_TYPE_BURN,
        fee     => 1 * DENOMINATOR,
    );
    $burn_tx->calculate_hash;

    is($burn_tx->validate, 0,
        "burn tx spending freeze1 UTXO passes the freeze1 restriction check");

    $transaction_module->unmock('check_input_script');
}

# -----------------------------------------------------------------------
# 5. Bitcoin P2SH downgrade output
#    P2SH Base58Check address (version byte 0x05) — same flow as P2PKH.
# -----------------------------------------------------------------------
{
    my $hex = create_raw_tx(
        [ { txid => $fake_txid, vout => 0 } ],
        [ { $btc_p2sh_addr => 1.5 } ],
    );
    ok(defined($hex) && length($hex),
        "createrawtransaction (P2SH downgrade): produces hex");

    my $decoded = decode_raw_tx($hex);
    ok($decoded, "decoderawtransaction (P2SH downgrade): decodes successfully");
    is($decoded->{type}, "standard",
        "P2SH downgrade tx type is 'standard'");
    is(scalar @{$decoded->{out}}, 1,
        "P2SH downgrade tx: one output");
    is($decoded->{out}[0]{address}, $btc_p2sh_addr,
        "P2SH downgrade output: P2SH address is shown");
    ok(!exists $decoded->{out}[0]{data},
        "P2SH downgrade output: no 'data' field");
    cmp_ok($decoded->{out}[0]{value}, '==', 1.5,
        "P2SH downgrade output: value is 1.5 QBTC");
}

# -----------------------------------------------------------------------
# 6. Bitcoin P2WPKH (SegWit / Bech32) downgrade output
# -----------------------------------------------------------------------
{
    my $hex = create_raw_tx(
        [ { txid => $fake_txid, vout => 0 } ],
        [ { $btc_p2wpkh_addr => 0.5 } ],
    );
    ok(defined($hex) && length($hex),
        "createrawtransaction (P2WPKH downgrade): produces hex");

    my $decoded = decode_raw_tx($hex);
    ok($decoded, "decoderawtransaction (P2WPKH downgrade): decodes successfully");
    is($decoded->{type}, "standard",
        "P2WPKH downgrade tx type is 'standard'");
    is(scalar @{$decoded->{out}}, 1,
        "P2WPKH downgrade tx: one output");
    is($decoded->{out}[0]{address}, $btc_p2wpkh_addr,
        "P2WPKH downgrade output: Bech32 address is shown");
    ok(!exists $decoded->{out}[0]{data},
        "P2WPKH downgrade output: no 'data' field");
    cmp_ok($decoded->{out}[0]{value}, '==', 0.5,
        "P2WPKH downgrade output: value is 0.5 QBTC");
}

# -----------------------------------------------------------------------
# 7. Bitcoin P2TR (Taproot / Bech32m) downgrade output
# -----------------------------------------------------------------------
{
    my $hex = create_raw_tx(
        [ { txid => $fake_txid, vout => 0 } ],
        [ { $btc_p2tr_addr => 2.0 } ],
    );
    ok(defined($hex) && length($hex),
        "createrawtransaction (P2TR downgrade): produces hex");

    my $decoded = decode_raw_tx($hex);
    ok($decoded, "decoderawtransaction (P2TR downgrade): decodes successfully");
    is($decoded->{type}, "standard",
        "P2TR downgrade tx type is 'standard'");
    is(scalar @{$decoded->{out}}, 1,
        "P2TR downgrade tx: one output");
    is($decoded->{out}[0]{address}, $btc_p2tr_addr,
        "P2TR downgrade output: Bech32m address is shown");
    ok(!exists $decoded->{out}[0]{data},
        "P2TR downgrade output: no 'data' field");
    cmp_ok($decoded->{out}[0]{value}, '==', 2.0,
        "P2TR downgrade output: value is 2.0 QBTC");
}

done_testing();
