package QBitcoin::StakingKey;
use warnings;
use strict;

# Long-lived staking keys of a delegate node. One key serves any number of
# delegated-staking addresses (see QBitcoin::Delegation): the delegate
# publishes the base58 form of its pubkeyhash (hash160 for pre-quantum keys,
# hash256 for post-quantum ones) once, and each owner builds a covenant
# address from it and their own key. A staking key can only sign the stake
# branch of the delegation covenant - it never controls money - so these keys
# live in their own table, separate from my_address.
#
# The private key is stored as WIF, encrypted with the wallet master key when
# the wallet is encrypted; the ciphertext is bound to the base58 pubkeyhash
# string the same way my_address ciphertexts are bound to the address.

use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::ORM qw(find update delete :types);
use QBitcoin::Crypto qw(pk_import pk_alg);
use QBitcoin::Address qw(wif_to_pk pubkeyhash_str pubkeyhash_by_pubkey);
use QBitcoin::Wallet::Crypt qw(is_encrypted_pk decrypt_pk unlocked);

use constant TABLE => 'staking_key';

use constant FIELDS => {
    id          => NUMERIC,
    private_key => STRING,
    pubkey      => BINARY,
    algo        => NUMERIC,
};

use constant PRIMARY_KEY => 'id';

mk_accessors(qw(id private_key pubkey algo));

my $STAKING_KEYS;

sub list {
    my $class = shift // __PACKAGE__;
    $STAKING_KEYS //= [ $class->find() ];
    return @$STAKING_KEYS;
}

sub get_by_pubkeyhash {
    my $class = shift;
    my ($pubkeyhash) = @_;
    my ($key) = grep { $_->pubkeyhash eq $pubkeyhash } $class->list;
    return $key;
}

sub pubkeyhash {
    my $self = shift;
    return $self->{pubkeyhash} //= pubkeyhash_by_pubkey($self->pubkey, $self->algo);
}

sub pubkeyhash_string {
    my $self = shift;
    return pubkeyhash_str($self->pubkeyhash);
}

# Plaintext WIF; dies when the key is encrypted and the wallet is locked
sub wif {
    my $self = shift;
    my $private_key = $self->private_key;
    is_encrypted_pk($private_key)
        or return $private_key;
    unlocked()
        or die "Wallet is locked\n";
    return decrypt_pk($private_key, $self->pubkeyhash_string)
        // die "Cannot decrypt staking key " . $self->pubkeyhash_string . "\n";
}

sub privkey {
    my $self = shift;
    my $algo = $self->algo;
    return $self->{privkey} //= pk_import(wif_to_pk($self->wif), $algo);
}

sub create {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    $attr->{private_key} && $attr->{pubkey} && $attr->{algo}
        or die "Missing private_key, pubkey or algo for staking key";
    if (my $existing = $class->get_by_pubkeyhash(pubkeyhash_by_pubkey($attr->{pubkey}, $attr->{algo}))) {
        Errf("Staking key %s already exists", $existing->pubkeyhash_string);
        return undef;
    }
    my $self = QBitcoin::ORM::create($class, $attr);
    if ($self) {
        Infof("Created staking key %s", $self->pubkeyhash_string);
        push @$STAKING_KEYS, $self if $STAKING_KEYS;
    }
    return $self;
}

# Delete the key from the database (delegations cascade in the DB) and drop the
# in-memory caches, including the delegations built on this key
sub remove {
    my $self = shift;
    require QBitcoin::Delegation;
    foreach my $delegation (grep { $_->staking_key_id == $self->id } QBitcoin::Delegation->list) {
        $delegation->remove;
    }
    $self->delete;
    @$STAKING_KEYS = grep { $_ != $self } @$STAKING_KEYS if $STAKING_KEYS;
    Warningf("Removed staking key %s", $self->pubkeyhash_string);
    return;
}

1;
