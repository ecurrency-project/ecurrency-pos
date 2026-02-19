package QBitcoin::MyAddress;
use warnings;
use strict;

use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::Const;
use QBitcoin::ORM qw(find update :types);
use QBitcoin::Crypto qw(hash160 hash256 pk_import pk_alg);
use QBitcoin::Address qw(wif_to_pk address_by_pubkey script_by_pubkey script_by_pubkeyhash addresses_by_pubkey);

use Exporter qw(import);
our @EXPORT_OK = qw(my_address stake_address);

use constant TABLE => 'my_address';

use constant FIELDS => {
    address     => STRING,
    private_key => STRING,
    staked      => NUMERIC,
};

use constant PRIMARY_KEY => 'address';

mk_accessors(qw(private_key staked));

my $MY_ADDRESS;
my $MY_HASHES;
my $STAKE_ADDRESS;

sub my_address {
    my $class = shift // __PACKAGE__;
    $MY_ADDRESS //= [ $class->find() ];
    return wantarray ? @$MY_ADDRESS : $MY_ADDRESS->[0];
}

sub stake_address {
    my $class = shift // __PACKAGE__;
    $STAKE_ADDRESS //= [ grep { $_->staked } $class->my_address ];
    return wantarray ? @$STAKE_ADDRESS : $STAKE_ADDRESS->[0];
}

sub pubkey {
    my $self = shift;
    return $self->{pubkey} if $self->{pubkey};
    my ($pk_alg) = $self->algo
        or return undef;
    my $pk = $self->privkey($pk_alg);
    return $self->{pubkey} = $pk->pubkey_by_privkey;
}

sub privkey {
    my $self = shift;
    my ($algo) = @_;
    my $private_key = $self->private_key
        or return undef;
    return $self->{privkey}->[$algo] //= pk_import(wif_to_pk($private_key), $algo);
}

sub algo {
    my $self = shift;
    my $private_key = $self->private_key
        or return ();
    return @{$self->{algo} //= [ pk_alg(wif_to_pk($private_key)) ]};
}

sub pubkeyhash {
    my $self = shift;
    return hash160($self->pubkey);
}

sub create {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    my $self = QBitcoin::ORM::create($class, $attr);
    if ($self) {
        Infof("Created my address %s", $self->address);
        push @$MY_ADDRESS, $self if $MY_ADDRESS;
        undef $MY_HASHES; # Clear cache
        # Do not forget to load utxo for this address by QBitcoin::Generate->load_address_utxo()
    }
    return $self;
}

sub address {
    my $self = shift;
    if (!$self->{addr}) {
        $self->{addr} = address_by_pubkey($self->pubkey // (return undef), $self->algo // return undef);
        if ($self->{address} && $self->{address} ne $self->{addr}) {
            my @addr = addresses_by_pubkey($self->pubkey, $self->algo);
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
    return map { hash160($_), hash256($_) } $self->redeem_script if wantarray;
    return $self->algo & CRYPT_ALGO_POSTQUANTUM ? hash256(scalar $self->redeem_script) : hash160(scalar $self->redeem_script);
}

sub get_by_hash {
    my $class = shift;
    my ($hash) = @_;
    if (!$MY_HASHES) {
        $MY_HASHES = {};
        foreach my $address (my_address()) {
            foreach my $scripthash ($address->scripthash) {
                $MY_HASHES->{$scripthash} = $address;
            }
        }
    }
    return $MY_HASHES->{$hash};
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
