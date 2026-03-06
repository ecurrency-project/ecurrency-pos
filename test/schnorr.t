#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;

use QBitcoin::Config;
use QBitcoin::Const;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(script_eval op_pushdata);
use QBitcoin::Crypto qw(signature hash256 generate_keypair pk_import check_sig);
use QBitcoin::Address qw(wallet_import_format wif_to_pk address_by_pubkey addresses_by_pubkey);
use QBitcoin::MyAddress;

# Test 1: Generate Schnorr keypair and check pubkey is 32 bytes (x-only, BIP-340)
my $pk = generate_keypair(CRYPT_ALGO_SCHNORR);
my $pubkey = $pk->pubkey_by_privkey;
is(length($pubkey), 32, "schnorr pubkey is 32 bytes (x-only)");

# Test 2: ECDSA pubkey remains 33 bytes
my $pk_ecdsa = generate_keypair(CRYPT_ALGO_ECDSA);
my $pubkey_ecdsa = $pk_ecdsa->pubkey_by_privkey;
is(length($pubkey_ecdsa), 33, "ecdsa pubkey is 33 bytes (compressed)");

# Test 3: Schnorr pubkey is valid
ok(QBitcoin::Crypto::Schnorr::secp256k1->is_valid_pubkey($pubkey), "schnorr pubkey passes validation");

# Test 4: ECDSA pubkey is not valid as Schnorr
ok(!QBitcoin::Crypto::Schnorr::secp256k1->is_valid_pubkey($pubkey_ecdsa), "ecdsa pubkey fails schnorr validation");

# Test 5: Schnorr signature is 64 bytes (BIP-340)
my $sign_data = "\x55\xaa" x 700;
my $raw_sig = $pk->signature(hash256($sign_data));
is(length($raw_sig), 64, "schnorr raw signature is 64 bytes");

# Test 6: Verify Schnorr signature via check_sig
my $algo_sig = pack("C", CRYPT_ALGO_SCHNORR) . $raw_sig;
ok(check_sig($sign_data, $algo_sig, $pubkey), "schnorr signature verification via check_sig");

# Test 7: Schnorr signature fails with wrong pubkey
my $pk2 = generate_keypair(CRYPT_ALGO_SCHNORR);
ok(!check_sig($sign_data, $algo_sig, $pk2->pubkey_by_privkey), "schnorr signature fails with wrong pubkey");

# Test 8: Schnorr signature fails with wrong data
ok(!check_sig("wrong data" x 100, $algo_sig, $pubkey), "schnorr signature fails with wrong data");

# Test 9: Private key serialize/import roundtrip
my $serialized = $pk->pk_serialize;
is(length($serialized), 32, "schnorr private key is 32 bytes");
my $pk_reimported = pk_import($serialized, CRYPT_ALGO_SCHNORR);
is($pk_reimported->pubkey_by_privkey, $pubkey, "schnorr key roundtrip preserves pubkey");

# Test 10: WIF roundtrip
my $wif = wallet_import_format($serialized);
my $raw_pk = wif_to_pk($wif);
is($raw_pk, $serialized, "WIF roundtrip preserves private key");

# Test 11: Schnorr address differs from ECDSA address (different pubkey format)
my $schnorr_addr = address_by_pubkey($pubkey, CRYPT_ALGO_SCHNORR);
my $pk_ecdsa_from_same = pk_import($serialized, CRYPT_ALGO_ECDSA);
my $ecdsa_addr = address_by_pubkey($pk_ecdsa_from_same->pubkey_by_privkey, CRYPT_ALGO_ECDSA);
isnt($schnorr_addr, $ecdsa_addr, "schnorr and ecdsa addresses differ for same private key");

# Test 12: Key normalization - compressed prefix is always \x02 (even y)
foreach my $i (1..20) {
    my $kp = generate_keypair(CRYPT_ALGO_SCHNORR);
    my $compressed = $kp->pk->export_key_raw('public_compressed');
    is(substr($compressed, 0, 1), "\x02", "keypair $i: normalized to even y (\\x02 prefix)");
}

# Test 13: Import normalization - even after importing a key that had odd y
{
    # Generate an ECDSA key (no normalization), find one with odd y
    my $odd_key;
    foreach (1..100) {
        my $kp = Crypt::PK::ECC::Schnorr->new;
        $kp->generate_key('secp256k1');
        if (substr($kp->export_key_raw('public_compressed'), 0, 1) eq "\x03") {
            $odd_key = $kp->export_key_raw('private');
            last;
        }
    }
    if ($odd_key) {
        my $imported = pk_import($odd_key, CRYPT_ALGO_SCHNORR);
        my $compressed = $imported->pk->export_key_raw('public_compressed');
        is(substr($compressed, 0, 1), "\x02", "imported odd-y key normalized to even y");
        # Verify sign/verify still works
        my $sig = $imported->signature(hash256("test"));
        my $full_sig = pack("C", CRYPT_ALGO_SCHNORR) . $sig;
        ok(check_sig("test", $full_sig, $imported->pubkey_by_privkey), "sign/verify works after normalization");
    }
    else {
        fail("could not generate odd-y key for normalization test");
    }
}

# Test 14: Script execution with Schnorr (OP_CHECKSIG)
my $myaddr = QBitcoin::MyAddress->new(
    private_key => $wif,
    algo        => CRYPT_ALGO_SCHNORR,
);
is(length($myaddr->pubkey), 32, "MyAddress with schnorr algo returns 32-byte pubkey");
my $redeem_script = OP_DUP . OP_HASH256 . op_pushdata(hash256($myaddr->pubkey)) . OP_EQUALVERIFY . OP_CHECKSIG;
my $sig_full = signature($sign_data, $myaddr, CRYPT_ALGO_SCHNORR, SIGHASH_ALL);
my $siglist = [ $sig_full, $myaddr->pubkey ];
my $tx = TestTx->new(sign_data => $sign_data);
my $res = script_eval($siglist, $redeem_script, $tx, 0);
ok($res, "schnorr checksig via script_eval");

# Test 15: Script execution fails with wrong key
my $myaddr2 = QBitcoin::MyAddress->new(
    private_key => wallet_import_format($pk2->pk_serialize),
    algo        => CRYPT_ALGO_SCHNORR,
);
my $siglist2 = [ $sig_full, $myaddr2->pubkey ];
$res = script_eval($siglist2, $redeem_script, $tx, 0);
ok(!$res, "schnorr checksig fails with wrong pubkey");

# Test 16: Multiple keypairs sign/verify
foreach my $i (1..10) {
    my $kp = generate_keypair(CRYPT_ALGO_SCHNORR);
    my $pub = $kp->pubkey_by_privkey;
    is(length($pub), 32, "keypair $i: pubkey is 32 bytes");
    my $sig = $kp->signature(hash256("test message $i"));
    my $full_sig = pack("C", CRYPT_ALGO_SCHNORR) . $sig;
    ok(check_sig("test message $i", $full_sig, $pub), "keypair $i: sign/verify works");
}

done_testing();

package TestTx;
use warnings;
use strict;

use QBitcoin::Accessors qw(new);
sub sign_data { $_[0]->{sign_data} };

1;
