package QBitcoin::Wallet;
use warnings;
use strict;

# Two-tier encryption of the wallet private keys stored in the my_address table.
#
# A random 256-bit master key encrypts each private key; the master key itself
# is stored in the `setting` table wrapped with a KEK derived from the wallet
# password. "Keys are encrypted" == the wrapped master key record exists; there
# is no separate flag. Changing the password only rewraps this single record.
# The unwrapped master key lives in process memory while the wallet is unlocked;
# the node is a single process, so RPC, REST and block generation all see it.
#
# The cryptography and the in-memory master-key state live in QBitcoin::Wallet::Crypt

use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Password;
use QBitcoin::MyAddress;
use QBitcoin::Wallet::Crypt qw(
    unlock_master_key
    wipe_master_key
    set_master_key
    generate_master_key
    wrap_master_key
    unwrap_master_key
    store_master_key
);

# Class-method facade over QBitcoin::Wallet::Crypt (fully qualified where the
# name coincides with the method)
sub is_encrypted      { QBitcoin::Wallet::Crypt::is_encrypted() }
sub unlocked          { QBitcoin::Wallet::Crypt::unlocked() }
sub signing_available { QBitcoin::Wallet::Crypt::signing_available() }
sub is_encrypted_pk   { shift; QBitcoin::Wallet::Crypt::is_encrypted_pk(@_) }
sub encrypt_pk        { shift; QBitcoin::Wallet::Crypt::encrypt_pk(@_) }
sub decrypt_pk        { shift; QBitcoin::Wallet::Crypt::decrypt_pk(@_) }
sub unlock            { shift; unlock_master_key(@_) }

# Unwrap the master key for a single operation (dumpprivkey, import into a
# locked wallet) without leaving the wallet unlocked
sub master_key_with_password { shift; unwrap_master_key(@_) }

sub lock {
    my $class = shift;
    wipe_master_key();
    # Drop decrypted key objects cached on the address objects; the pubkey-derived
    # caches (scripthash maps etc.) are not secret and stay valid.
    delete $_->{privkey} foreach QBitcoin::MyAddress->my_address;
    return 1;
}

# Encrypt all plaintext private keys with $master; also stores the pubkey so a
# locked node can still derive addresses/scripthashes and load its UTXO.
# Returns the number of keys encrypted.
sub encrypt_all {
    my $class = shift;
    my ($master) = @_;
    my $count = 0;
    foreach my $address (QBitcoin::MyAddress->watched_address) {
        my $stored = $address->private_key;
        next if !$stored || $class->is_encrypted_pk($stored);
        my $pubkey = $address->pubkey; # derive from the plaintext key before replacing it
        $address->update(
            private_key => $class->encrypt_pk($stored, $address->address, $master),
            defined($pubkey) ? (pubkey => $pubkey) : (),
        );
        $count++;
    }
    return $count;
}

# Decrypt all encrypted private keys back to plaintext WIF. Two-phase: decrypt
# everything into memory first, write only if all records decrypted successfully.
# Returns the number of keys decrypted, undef on failure (nothing written).
sub decrypt_all {
    my $class = shift;
    my ($master) = @_;
    my @decrypted;
    foreach my $address (QBitcoin::MyAddress->watched_address) {
        my $stored = $address->private_key;
        next if !$stored || !$class->is_encrypted_pk($stored);
        my $wif = $class->decrypt_pk($stored, $address->address, $master);
        if (!defined $wif) {
            Errf("Cannot decrypt private key for address %s", $address->address);
            return undef;
        }
        push @decrypted, [ $address, $wif ];
    }
    $_->[0]->update(private_key => $_->[1]) foreach @decrypted;
    return scalar @decrypted;
}

sub encrypted_count {
    my $class = shift;
    return scalar grep { $_->private_key && $class->is_encrypted_pk($_->private_key) }
        QBitcoin::MyAddress->watched_address;
}

# Set or change the wallet password and converge the key-encryption state to the
# encrypted_private_keys config policy (default 1). This is the only moment both
# the old and the new passwords are known, so both transitions happen here.
# $old is the verified current password (undef when no password was set).
# Returns undef on success or an error message.
sub change_password {
    my $class = shift;
    my ($old, $new) = @_;
    my $policy = $config->{encrypted_private_keys} // 1;
    if ($class->is_encrypted) {
        my $master = defined($old) ? unwrap_master_key($old) : undef;
        if (!defined $master) {
            # Possible only on state skew (auth hash and wrapped key set with
            # different passwords, e.g. after manual DB edits)
            return "Cannot unwrap the wallet master key with the current password";
        }
        if ($policy) {
            # Rewrap the master key with the new password; single-row atomic update
            store_master_key(wrap_master_key($master, $new));
            QBitcoin::Password->set_password($new);
        }
        else {
            # Decrypt keys first, remove the master key record last: a crash in
            # between leaves plaintext keys with a stale (harmless) master record
            my $count = $class->decrypt_all($master)
                // return "Cannot decrypt private keys";
            QBitcoin::Password->set_password($new);
            store_master_key(undef);
            wipe_master_key();
            Noticef("Decrypted %u wallet private keys (encrypted_private_keys is disabled)", $count);
        }
    }
    else {
        QBitcoin::Password->set_password($new);
        if ($policy && grep { $_->private_key } QBitcoin::MyAddress->watched_address) {
            my $master = generate_master_key();
            # Store the wrapped master key before encrypting the rows: a crash in
            # between leaves some keys in plaintext, readable and re-convergeable
            store_master_key(wrap_master_key($master, $new));
            my $count = $class->encrypt_all($master);
            set_master_key($master); # the operator has just set the password; stay unlocked
            Noticef("Encrypted %u wallet private keys", $count);
        }
    }
    return undef;
}

# Forgotten-password reset: the encrypted keys cannot be recovered without the
# old password, so they are destroyed. Returns the number of destroyed keys.
sub reset_destroy {
    my $class = shift;
    my ($new) = @_;
    my @encrypted = grep { $_->private_key && $class->is_encrypted_pk($_->private_key) }
        QBitcoin::MyAddress->watched_address;
    $_->remove foreach @encrypted;
    store_master_key(undef);
    wipe_master_key();
    QBitcoin::Password->set_password($new);
    Warningf("Wallet password reset: %u encrypted private keys destroyed", scalar @encrypted);
    return scalar @encrypted;
}

1;
