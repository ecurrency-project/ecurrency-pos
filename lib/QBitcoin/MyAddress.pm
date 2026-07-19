package QBitcoin::MyAddress;
use warnings;
use strict;

use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::Const;
use QBitcoin::ORM qw(find update delete :types);
use QBitcoin::Crypto qw(hash160 hash256 pk_import pk_alg);
use QBitcoin::Address qw(wif_to_pk address_by_pubkey script_by_pubkey script_by_pubkeyhash addresses_by_pubkey scripthash_by_address);
use QBitcoin::TXO;
use QBitcoin::Tag;
use QBitcoin::Wallet::Crypt qw(is_encrypted_pk decrypt_pk unlocked);

use Exporter qw(import);
our @EXPORT_OK = qw(my_address stake_address watched_address);

use constant TABLE => 'my_address';

use constant FIELDS => {
    address     => STRING,
    private_key => STRING,
    pubkey      => BINARY,
    staked      => NUMERIC,
    algo        => NUMERIC,
    tag_id      => NUMERIC,
};

use constant PRIMARY_KEY => 'address';

mk_accessors(qw(private_key staked algo tag_id));

my $MY_ADDRESS;
my $STAKE_ADDRESS;
my $WATCHED_ADDRESS;
my $MY_HASHES;
my $WATCH_HASHES;
my %TAG_CACHE;

sub watched_address {
    my $class = shift // __PACKAGE__;
    $WATCHED_ADDRESS //= [ $class->find() ];
    return wantarray ? @$WATCHED_ADDRESS : $WATCHED_ADDRESS->[0];
}

sub my_address {
    my $class = shift // __PACKAGE__;
    $MY_ADDRESS //= [ grep { $_->private_key } $class->watched_address ];
    return wantarray ? @$MY_ADDRESS : $MY_ADDRESS->[0];
}

sub stake_address {
    my $class = shift // __PACKAGE__;
    $STAKE_ADDRESS //= [ grep { $_->staked } $class->my_address ];
    return wantarray ? @$STAKE_ADDRESS : $STAKE_ADDRESS->[0];
}

# Change staked to unstaked or unstaked to staked for the given address
sub update_my_utxo {
    my $address = shift;
    my %scripthash = map { $_ => 1 } $address->scripthash;
    foreach my $utxo (grep { exists $scripthash{$_->scripthash} } QBitcoin::TXO->my_utxo()) {
        $utxo->del_my_utxo;
        $utxo->add_my_utxo;
    }
}

sub set_stake {
    my $self = shift;
    my ($value) = @_;
    return 1 if ($self->staked ? 1 : 0) == ($value ? 1 : 0);
    return 0 unless $self->private_key;
    $self->update(staked => $value ? 1 : 0);
    update_my_utxo($self);
    if ($STAKE_ADDRESS) {
        if ($value) {
            push @$STAKE_ADDRESS, $self;
        } else {
            @$STAKE_ADDRESS = grep { $_->address ne $self->address } @$STAKE_ADDRESS;
        }
    }
    return 1;
}

sub tag {
    my $self = shift;
    my $tag_id = $self->tag_id or return undef;
    if (!exists $TAG_CACHE{$tag_id}) {
        my $tag_obj = QBitcoin::Tag->find(id => $tag_id);
        $TAG_CACHE{$tag_id} = $tag_obj ? $tag_obj->tag : undef;
    }
    return $TAG_CACHE{$tag_id};
}

sub pubkey {
    my $self = shift;
    if (@_) { # setter, called by update(pubkey => ...)
        return $self->{pubkey} = $_[0];
    }
    return $self->{pubkey} if $self->{pubkey}; # stored in the database or already derived
    my $pk_alg = $self->_pk_alg
        or return undef;
    my $pk = $self->privkey($pk_alg)
        or return undef;
    return $self->{pubkey} = $pk->pubkey_by_privkey;
}

# Plaintext WIF for this address; undef for watch-only.
# Dies when the key is encrypted and the wallet is locked.
sub wif {
    my $self = shift;
    my $private_key = $self->private_key
        or return undef;
    is_encrypted_pk($private_key)
        or return $private_key;
    unlocked()
        or die "Wallet is locked\n";
    return decrypt_pk($private_key, $self->{address})
        // die "Cannot decrypt private key for address $self->{address}\n";
}

sub privkey {
    my $self = shift;
    my ($algo) = @_;
    $self->private_key
        or return undef;
    return $self->{privkey}->[$algo] //= pk_import(wif_to_pk($self->wif), $algo);
}

# Primary algorithm for this address (scalar)
sub _pk_alg {
    my $self = shift;
    # Use stored algo if available
    return $self->{algo} if $self->{algo};
    # Determine from private key: try all matching algorithms,
    # pick the one whose pubkey matches the stored address
    my $private_key = $self->wif
        or return undef;
    my @algos = pk_alg(wif_to_pk($private_key));
    return undef unless @algos;
    if ($self->{address} && @algos > 1) {
        foreach my $algo (@algos) {
            my $pk = $self->privkey($algo) or next;
            my $pubkey = $pk->pubkey_by_privkey;
            if (address_by_pubkey($pubkey, $algo) eq $self->{address}) {
                return $self->{algo} = $algo;
            }
            # Also check alternative addresses
            my @addrs = addresses_by_pubkey($pubkey, $algo);
            if (grep { $_ eq $self->{address} } @addrs) {
                return $self->{algo} = $algo;
            }
        }
    }
    return $self->{algo} = $algos[0];
}

# All matching algorithms for this private key (list)
sub algo_list {
    my $self = shift;
    my $private_key = $self->wif
        or return ();
    return @{$self->{algo_list} //= [ pk_alg(wif_to_pk($private_key)) ]};
}

sub pubkeyhash {
    my $self = shift;
    return hash160($self->pubkey);
}

sub create {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    $attr->{address} or die "Missing address";
    if ($attr->{private_key}) {
        my $scripthash = scripthash_by_address($attr->{address});
        if (my $address = $class->get_by_hash($scripthash, 1)) {
            if ($address->private_key) {
                Errf("Address %s already exists with private key", $attr->{address});
                return undef;
            }
            else {
                Infof("Updating watch-only address %s with private key", $attr->{address});
                $class->_derive_pubkey($attr);
                $address->update(
                    private_key => $attr->{private_key},
                    $attr->{pubkey} ? (pubkey => $attr->{pubkey}) : (),
                );
                push @$MY_ADDRESS, $address if $MY_ADDRESS;
                if ($attr->{staked}) {
                    $address->update(staked => 1);
                    push @$STAKE_ADDRESS, $address if $STAKE_ADDRESS;
                }
                if ($MY_HASHES) {
                    foreach my $scripthash ($address->scripthash) {
                        $MY_HASHES->{$scripthash} = $address;
                    }
                }
                return $address;
            }
        }
    }
    elsif ($attr->{staked}) {
        Errf("Cannot create watch-only address %s with staked flag", $attr->{address});
        return undef;
    }
    $class->_derive_pubkey($attr) if $attr->{private_key};
    my $self = QBitcoin::ORM::create($class, $attr);
    if ($self) {
        Infof("Created my address %s", $self->address);
        if ($WATCHED_ADDRESS) {
            push @$WATCHED_ADDRESS, $self;
            push @$MY_ADDRESS, $self if $MY_ADDRESS && $self->private_key;
            push @$STAKE_ADDRESS, $self if $STAKE_ADDRESS && $self->staked;
        }
        if ($MY_HASHES) {
            if ($self->private_key) {
                foreach my $scripthash ($self->scripthash) {
                    $MY_HASHES->{$scripthash} = $self;
                    $WATCH_HASHES->{$scripthash} = $self;
                }
            }
            else {
                # Watch-only: derive scripthash from address string
                my $scripthash = scripthash_by_address($self->address);
                $WATCH_HASHES->{$scripthash} = $self;
            }
        }
        # Do not forget to load utxo for this address by QBitcoin::Generate->load_address_utxo()
    }
    return $self;
}

# Fill $attr->{pubkey} from a plaintext private key (callers storing an encrypted
# key must pass the pubkey explicitly)
sub _derive_pubkey {
    my $class = shift;
    my ($attr) = @_;
    return if $attr->{pubkey} || is_encrypted_pk($attr->{private_key});
    my $tmp = $class->new({
        private_key => $attr->{private_key},
        address     => $attr->{address},
        $attr->{algo} ? (algo => $attr->{algo}) : (),
    });
    $attr->{pubkey} = $tmp->pubkey;
    return;
}

# Fill the pubkey column for rows created before it existed. Needs the plaintext
# key, so it covers unencrypted rows only; encrypt_all() stores the pubkey for
# the rows it encrypts, so an encrypted row without pubkey is a broken one.
sub backfill_pubkeys {
    my $class = shift // __PACKAGE__;
    foreach my $address ($class->watched_address) {
        my $private_key = $address->private_key;
        next if $address->{pubkey} || !$private_key;
        if (is_encrypted_pk($private_key)) {
            Warningf("Address %s has encrypted private key but no stored pubkey; it is unusable while the wallet is locked", $address->address);
            next;
        }
        my $pubkey = $address->pubkey
            or next;
        $address->update(pubkey => $pubkey);
        Infof("Stored public key for address %s", $address->address);
    }
}

# Delete the address from the database and all in-memory caches, including its
# entries in the my-UTXO set (used by the forgotten-password reset)
sub remove {
    my $self = shift;
    # A row without a stored pubkey cannot derive its hashes while locked; it never
    # populated any caches either, so removing just the DB row is enough for it
    my %scripthash = map { $_ => 1 } eval { $self->scripthash };
    my %pubkeyhash;
    if (my $pubkey = eval { $self->pubkey }) {
        %pubkeyhash = (hash160($pubkey) => 1, hash256($pubkey) => 1);
    }
    require QBitcoin::TXO;
    foreach my $utxo (QBitcoin::TXO->my_utxo) {
        if ($scripthash{$utxo->scripthash} || $pubkeyhash{substr($utxo->data // "", 0, 32)}) {
            $utxo->del_my_utxo;
        }
    }
    $self->delete;
    @$WATCHED_ADDRESS = grep { $_ != $self } @$WATCHED_ADDRESS if $WATCHED_ADDRESS;
    @$MY_ADDRESS      = grep { $_ != $self } @$MY_ADDRESS      if $MY_ADDRESS;
    @$STAKE_ADDRESS   = grep { $_ != $self } @$STAKE_ADDRESS   if $STAKE_ADDRESS;
    if ($MY_HASHES) {
        foreach my $hash (keys %scripthash) {
            delete $MY_HASHES->{$hash};
            delete $WATCH_HASHES->{$hash};
        }
    }
    Warningf("Removed my address %s", $self->address);
    return;
}

sub is_watchonly {
    my $self = shift;
    return !$self->private_key;
}

sub address {
    my $self = shift;
    return $self->{address} if $self->is_watchonly;
    if (!$self->{addr}) {
        my $algo = $self->_pk_alg // return undef;
        $self->{addr} = address_by_pubkey($self->pubkey // (return undef), $algo);
        if ($self->{address} && $self->{address} ne $self->{addr}) {
            my @addr = addresses_by_pubkey($self->pubkey, $algo);
            if (grep { $_ eq $self->{address} } @addr ) {
                $self->{addr} = $self->{address};
            } else {
                Errf("Mismatch my private key and address: %s != %s", $self->{addr}, $self->{address});
            }
        }
    }
    return $self->{addr};
}

sub redeem_script {
    my $self = shift;
    my $main_script = script_by_pubkey($self->pubkey);
    return wantarray ? (
        $main_script,
        script_by_pubkeyhash($self->pubkeyhash),
    ) : $main_script;
}

sub scripthash {
    my $self = shift;
    return scripthash_by_address($self->address) if $self->is_watchonly;
    return map { hash160($_), hash256($_) } $self->redeem_script if wantarray;
    return ($self->_pk_alg // 0) & CRYPT_ALGO_POSTQUANTUM ? hash256(scalar $self->redeem_script) : hash160(scalar $self->redeem_script);
}

sub get_by_hash {
    my $class = shift;
    my ($hash, $include_watchonly) = @_;
    if (!$MY_HASHES) {
        $MY_HASHES = {};
        $WATCH_HASHES = {};
        foreach my $address (watched_address()) {
            if ($address->private_key) {
                foreach my $scripthash ($address->scripthash) {
                    $MY_HASHES->{$scripthash} = $address;
                    $WATCH_HASHES->{$scripthash} = $address;
                }
            }
            else {
                # Watch-only: derive scripthash from address string
                my $scripthash = scripthash_by_address($address->address);
                $WATCH_HASHES->{$scripthash} = $address;
            }
        }
    }
    return $include_watchonly ? $WATCH_HASHES->{$hash} : $MY_HASHES->{$hash};
}

sub script_by_hash {
    my $self = shift;
    my ($scripthash) = @_;
    if (!$self->{script}) {
        $self->{script} = {};
        foreach my $redeem_script ($self->redeem_script) {
            $self->{script}->{hash160($redeem_script)} = $redeem_script;
            $self->{script}->{hash256($redeem_script)} = $redeem_script;
        }
    }
    return $self->{script}->{$scripthash};
}

1;
