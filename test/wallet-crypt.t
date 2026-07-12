#! /usr/bin/env perl
use warnings;
use strict;

# QBitcoin::Wallet: master-key wrap/unwrap, private-key encrypt/decrypt,
# lock/unlock and the encrypt/decrypt convergence of change_password.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::Password;
use QBitcoin::Wallet;

$config->{regtest} = 1;

sub make_address {
    my ($algo) = @_;
    my $pk = generate_keypair($algo);
    my $pubkey = $pk->pubkey_by_privkey;
    my ($address) = addresses_by_pubkey($pubkey, $algo);
    my $wif = wallet_import_format($pk->pk_serialize);
    my $my_address = QBitcoin::MyAddress->create({
        private_key => $wif,
        address     => $address,
        algo        => $algo,
    });
    return ($my_address, $wif, $pubkey);
}

sub db_row {
    my ($address) = @_;
    return QBitcoin::MyAddress->find(address => $address);
}

my ($addr_ec, $wif_ec, $pubkey_ec) = make_address(CRYPT_ALGO_ECDSA);
my ($addr_pq, $wif_pq, $pubkey_pq) = make_address(CRYPT_ALGO_FALCON);

is(db_row($addr_ec->address)->private_key, $wif_ec, "plaintext WIF stored before encryption");
is(db_row($addr_ec->address)->pubkey, $pubkey_ec, "pubkey stored on create (ecdsa)");
is(db_row($addr_pq->address)->pubkey, $pubkey_pq, "pubkey stored on create (falcon)");

ok(!QBitcoin::Wallet->is_encrypted, "keys not encrypted initially");
ok(QBitcoin::Wallet->signing_available, "signing available without password");

# First password set with default policy (encrypted_private_keys = 1) encrypts the keys
is(QBitcoin::Wallet->change_password(undef, "pass1"), undef, "set the first password");
ok(QBitcoin::Password->check_password("pass1"), "auth hash set");
ok(QBitcoin::Wallet->is_encrypted, "keys encrypted after the first password set");
ok(QBitcoin::Wallet->unlocked, "wallet left unlocked after setting the password");
is(QBitcoin::Wallet->encrypted_count, 2, "both keys encrypted");

my $stored_ec = db_row($addr_ec->address)->private_key;
ok(QBitcoin::Wallet->is_encrypted_pk($stored_ec), "stored value has the encrypted format");
isnt($stored_ec, $wif_ec, "stored value is not the plaintext WIF");

# Decryption via the unlocked wallet
is(db_row($addr_ec->address)->wif, $wif_ec, "wif() decrypts the ecdsa key");
is(db_row($addr_pq->address)->wif, $wif_pq, "wif() decrypts the falcon key");

# The ciphertext is bound to its address (AAD)
is(QBitcoin::Wallet->decrypt_pk($stored_ec, $addr_ec->address), $wif_ec, "decrypt_pk with the correct address");
is(QBitcoin::Wallet->decrypt_pk($stored_ec, $addr_pq->address), undef, "decrypt_pk fails with another address");

# Lock / unlock
ok(QBitcoin::Wallet->lock, "lock");
ok(!QBitcoin::Wallet->unlocked, "locked");
ok(!QBitcoin::Wallet->signing_available, "signing unavailable while locked");
my $err = do { local $@; eval { db_row($addr_ec->address)->wif }; $@ };
like($err, qr/Wallet is locked/, "wif() dies while locked");
$err = do { local $@; eval { db_row($addr_ec->address)->privkey(CRYPT_ALGO_ECDSA) }; $@ };
like($err, qr/Wallet is locked/, "privkey() dies while locked");
is(db_row($addr_ec->address)->pubkey, $pubkey_ec, "pubkey still available while locked");
ok(scalar(db_row($addr_ec->address)->scripthash), "scripthash still available while locked");

ok(!QBitcoin::Wallet->unlock("wrong"), "unlock with a wrong password fails");
ok(!QBitcoin::Wallet->unlocked, "still locked");
ok(QBitcoin::Wallet->unlock("pass1"), "unlock with the correct password");
ok(QBitcoin::Wallet->signing_available, "signing available after unlock");
ok(db_row($addr_ec->address)->privkey(CRYPT_ALGO_ECDSA), "privkey import works after unlock");

# Transient unwrap does not change the lock state
QBitcoin::Wallet->lock;
ok(!QBitcoin::Wallet->master_key_with_password("wrong"), "transient unwrap fails with a wrong password");
my $master = QBitcoin::Wallet->master_key_with_password("pass1");
ok($master, "transient unwrap with the correct password");
ok(!QBitcoin::Wallet->unlocked, "wallet stays locked after the transient unwrap");
is(QBitcoin::Wallet->decrypt_pk($stored_ec, $addr_ec->address, $master), $wif_ec, "decrypt_pk with the transient master key");

# Password change rewraps the master key only; the key rows stay unchanged
is(QBitcoin::Wallet->change_password("pass1", "pass2"), undef, "change the password");
ok(QBitcoin::Password->check_password("pass2"), "auth hash updated");
ok(!QBitcoin::Wallet->unlocked, "locked wallet stays locked across a password change");
is(db_row($addr_ec->address)->private_key, $stored_ec, "key rows not rewritten on password change");
ok(!QBitcoin::Wallet->unlock("pass1"), "old password does not unlock");
ok(QBitcoin::Wallet->unlock("pass2"), "new password unlocks");

# Policy 0: the same command decrypts the keys back to plaintext
$config->{encrypted_private_keys} = 0;
is(QBitcoin::Wallet->change_password("pass2", "pass2"), undef, "converge to policy 0 with the same password");
ok(!QBitcoin::Wallet->is_encrypted, "master key removed");
is(db_row($addr_ec->address)->private_key, $wif_ec, "ecdsa key decrypted back to WIF");
is(db_row($addr_pq->address)->private_key, $wif_pq, "falcon key decrypted back to WIF");
ok(QBitcoin::Wallet->signing_available, "signing available with plaintext keys");

# Policy 1 again: re-encrypt
$config->{encrypted_private_keys} = 1;
is(QBitcoin::Wallet->change_password("pass2", "pass2"), undef, "converge back to policy 1");
ok(QBitcoin::Wallet->is_encrypted, "keys encrypted again");
is(QBitcoin::Wallet->encrypted_count, 2, "both keys encrypted again");
is(db_row($addr_ec->address)->wif, $wif_ec, "decryption still works");

# Forgotten-password reset destroys the encrypted keys
QBitcoin::Wallet->lock;
is(QBitcoin::Wallet->reset_destroy("pass3"), 2, "reset_destroy reports 2 destroyed keys");
ok(!QBitcoin::Wallet->is_encrypted, "master key removed by the reset");
ok(QBitcoin::Password->check_password("pass3"), "new password set by the reset");
is(db_row($addr_ec->address), undef, "encrypted address removed from the database");
is(scalar(() = QBitcoin::MyAddress->my_address), 0, "no addresses left in the in-memory cache");

done_testing();
