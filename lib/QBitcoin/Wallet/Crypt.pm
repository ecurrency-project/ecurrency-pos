package QBitcoin::Wallet::Crypt;
use warnings;
use strict;

# Low-level cryptography and in-memory master-key state for the wallet
# private-key encryption. Wallet-level operations (encrypting the whole
# wallet, password changes, resets) live in QBitcoin::Wallet, built on top
# of this module.
#
# Storage formats:
# - the master key is stored in the `setting` table under 'wallet_master_key',
#   wrapped with a KEK derived from the wallet password by PBKDF2 (its own
#   salt, independent from the QBitcoin::Password auth-hash salt):
#       v1$<iter>$<b64 salt>$<b64 nonce>$<b64 ciphertext||tag>
# - each private key is stored in my_address.private_key encrypted with the
#   master key (AES-256-GCM, per-record nonce, the address string as
#   associated data, which binds the ciphertext to its table row):
#       qenc1$<b64 nonce>$<b64 ciphertext||tag>
#   A plaintext WIF is base58 and cannot contain '$', so the qenc1$ prefix
#   unambiguously marks an encrypted value.

use Exporter qw(import);
our @EXPORT_OK = qw(
    is_encrypted
    unlocked
    signing_available
    unlock_master_key
    wipe_master_key
    set_master_key
    generate_master_key
    wrap_master_key
    unwrap_master_key
    store_master_key
    encrypt_pk
    decrypt_pk
    is_encrypted_pk
);

use Crypt::AuthEnc::GCM qw(gcm_encrypt_authenticate gcm_decrypt_verify);
use Crypt::KeyDerivation qw(pbkdf2);
use Crypt::PRNG qw(random_bytes);
use MIME::Base64 qw(encode_base64 decode_base64);
use QBitcoin::Setting;

use constant SETTING_NAME => 'wallet_master_key';

use constant {
    PBKDF2_HASH => 'SHA256',
    PBKDF2_ITER => 100_000,
    SALT_LEN    => 16,
    KEY_LEN     => 32,
    NONCE_LEN   => 12,
    CIPHER      => 'AES',
    PK_PREFIX   => 'qenc1',
};

# In-memory cache of the stored wrapped master key (same pattern as QBitcoin::Password)
my $CACHE;
my $CACHE_LOADED;
# Unwrapped master key while the wallet is unlocked
my $MASTER_KEY;

sub _stored {
    if (!$CACHE_LOADED) {
        $CACHE = QBitcoin::Setting->get(SETTING_NAME);
        $CACHE_LOADED = 1;
    }
    return $CACHE;
}

# Persist the wrapped master key (undef removes the record)
sub store_master_key {
    my ($value) = @_;
    if (defined $value) {
        QBitcoin::Setting->set(SETTING_NAME, $value);
    }
    else {
        QBitcoin::Setting->unset(SETTING_NAME);
    }
    $CACHE = $value;
    $CACHE_LOADED = 1;
    return;
}

# "Keys are encrypted" == the wrapped master key record exists
sub is_encrypted {
    return defined(_stored()) ? 1 : 0;
}

sub unlocked {
    return defined($MASTER_KEY) ? 1 : 0;
}

# Signing is possible: either the keys are stored in plaintext or the wallet is unlocked
sub signing_available {
    return is_encrypted() ? unlocked() : 1;
}

sub generate_master_key {
    return random_bytes(KEY_LEN);
}

# Keep an already unwrapped master key in memory (the wallet becomes unlocked)
sub set_master_key {
    ($MASTER_KEY) = @_;
    return;
}

# Remove the master key from memory; QBitcoin::Wallet::lock also clears the
# per-address caches of decrypted keys
sub wipe_master_key {
    undef $MASTER_KEY;
    return;
}

# Wrap the master key with a password-derived KEK
sub wrap_master_key {
    my ($master, $password) = @_;
    my $salt  = random_bytes(SALT_LEN);
    my $nonce = random_bytes(NONCE_LEN);
    my $kek   = pbkdf2($password, $salt, PBKDF2_ITER, PBKDF2_HASH, KEY_LEN);
    my ($ct, $tag) = gcm_encrypt_authenticate(CIPHER, $kek, $nonce, SETTING_NAME, $master);
    return sprintf("v1\$%d\$%s\$%s\$%s", PBKDF2_ITER,
        encode_base64($salt, ""), encode_base64($nonce, ""), encode_base64($ct . $tag, ""));
}

# Unwrap the stored master key with the given password; undef if the password
# does not match (or the record is corrupted). Does not change the lock state.
sub unwrap_master_key {
    my ($password) = @_;
    my $stored = _stored()
        // return undef;
    my ($iter, $salt_b64, $nonce_b64, $data_b64) = $stored =~ /^v1\$(\d+)\$([^\$]+)\$([^\$]+)\$([^\$]+)\z/
        or return undef;
    my $salt  = decode_base64($salt_b64);
    my $nonce = decode_base64($nonce_b64);
    my $data  = decode_base64($data_b64);
    length($data) > 16
        or return undef;
    my $kek = pbkdf2($password, $salt, $iter + 0, PBKDF2_HASH, KEY_LEN);
    # copy the substrings: the XS function rejects the magic SV substr() passes as an argument
    my $ct  = substr($data, 0, -16);
    my $tag = substr($data, -16);
    return gcm_decrypt_verify(CIPHER, $kek, $nonce, SETTING_NAME, $ct, $tag);
}

# Unwrap the master key and keep it in memory (the wallet becomes unlocked)
sub unlock_master_key {
    my ($password) = @_;
    my $master = unwrap_master_key($password)
        or return 0;
    $MASTER_KEY = $master;
    return 1;
}

sub is_encrypted_pk {
    my ($value) = @_;
    return defined($value) && index($value, PK_PREFIX . '$') == 0 ? 1 : 0;
}

# Encrypt a WIF private key with the master key ($master defaults to the
# in-memory one; undef when the wallet is locked)
sub encrypt_pk {
    my ($wif, $address, $master) = @_;
    $master //= $MASTER_KEY
        // return undef;
    my $nonce = random_bytes(NONCE_LEN);
    my ($ct, $tag) = gcm_encrypt_authenticate(CIPHER, $master, $nonce, $address, $wif);
    return sprintf("%s\$%s\$%s", PK_PREFIX, encode_base64($nonce, ""), encode_base64($ct . $tag, ""));
}

# Decrypt a stored qenc1$ value back to WIF; undef on wrong key or tampered data
sub decrypt_pk {
    my ($blob, $address, $master) = @_;
    $master //= $MASTER_KEY
        // return undef;
    my ($nonce_b64, $data_b64) = $blob =~ /^\Q@{[PK_PREFIX]}\E\$([^\$]+)\$([^\$]+)\z/
        or return undef;
    my $nonce = decode_base64($nonce_b64);
    my $data  = decode_base64($data_b64);
    length($data) > 16
        or return undef;
    # copy the substrings: the XS function rejects the magic SV substr() passes as an argument
    my $ct  = substr($data, 0, -16);
    my $tag = substr($data, -16);
    return gcm_decrypt_verify(CIPHER, $master, $nonce, $address, $ct, $tag);
}

1;
