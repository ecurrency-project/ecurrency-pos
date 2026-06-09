package QBitcoin::Password;
use warnings;
use strict;

# Single shared "wallet password" that guards the /admin/* and /wallet/* REST API.
# Stored hashed (PBKDF2) in the `setting` table; never kept in plaintext.

use Crypt::KeyDerivation qw(pbkdf2);
use Crypt::PRNG qw(random_bytes);
use MIME::Base64 qw(encode_base64 decode_base64);
use QBitcoin::Setting;

use constant SETTING_NAME => 'wallet_password';

use constant {
    PBKDF2_HASH => 'SHA256',
    PBKDF2_ITER => 100_000,
    SALT_LEN    => 16,
    DK_LEN      => 32,
    MAX_LEN     => 1024, # cap input length to bound PBKDF2 cost
};

# In-memory cache of the stored hash string (the node is a single long-running
# process, so we can safely invalidate the cache whenever we change it ourselves).
my $CACHE;        # stored encoded hash, or undef if no password is set
my $CACHE_LOADED; # whether $CACHE reflects the database

sub _stored {
    if (!$CACHE_LOADED) {
        $CACHE = QBitcoin::Setting->get(SETTING_NAME);
        $CACHE_LOADED = 1;
    }
    return $CACHE;
}

sub _store {
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

sub is_set {
    my $class = shift;
    return defined(_stored()) ? 1 : 0;
}

sub set_password {
    my $class = shift;
    my ($plain) = @_;
    my $salt = random_bytes(SALT_LEN);
    my $dk   = pbkdf2($plain, $salt, PBKDF2_ITER, PBKDF2_HASH, DK_LEN);
    my $encoded = sprintf("pbkdf2-%s\$%d\$%s\$%s",
        lc(PBKDF2_HASH), PBKDF2_ITER, encode_base64($salt, ""), encode_base64($dk, ""));
    _store($encoded);
    return 1;
}

sub check_password {
    my $class = shift;
    my ($plain) = @_;
    my $stored = _stored()
        // return 0;
    my ($algo, $iter, $salt_b64, $hash_b64) = $stored =~ /^pbkdf2-(\w+)\$(\d+)\$([^\$]+)\$([^\$]+)\z/
        or return 0;
    my $salt   = decode_base64($salt_b64);
    my $expect = decode_base64($hash_b64);
    my $dk = pbkdf2($plain, $salt, $iter + 0, uc($algo), length($expect));
    return _const_eq($dk, $expect);
}

sub reset_password {
    my $class = shift;
    _store(undef);
    return 1;
}

# Constant-time comparison to avoid leaking the hash via timing
sub _const_eq {
    my ($a, $b) = @_;
    return 0 if length($a) != length($b);
    my $diff = 0;
    $diff |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1)) for 0 .. length($a) - 1;
    return $diff == 0 ? 1 : 0;
}

1;
