package QBitcoin::Delegation;
use warnings;
use strict;

# An address delegated to this node for staking: the owner key belongs to
# someone else, our staking key (see QBitcoin::StakingKey) can sign only the
# stake branch of the covenant script (see QBitcoin::Script::Delegation).
# These addresses are tracked separately from my_address: their UTXOs are
# staked but never counted in the wallet balance and never spendable here.
#
# When the owner key is also in this wallet (the node plays both roles), the
# same address simply has a row in my_address too; the two tables do not
# conflict and neither depends on the import order.

use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::ORM qw(find delete :types);
use QBitcoin::Address qw(scripthash_by_address);
use QBitcoin::Script::Delegation qw(delegation_script delegation_address);
use QBitcoin::StakingKey;
use QBitcoin::Wallet::UTXO ();

use constant TABLE => 'delegation';

use constant FIELDS => {
    address          => STRING,
    staking_key_id   => NUMERIC,
    owner_pubkeyhash => BINARY,
};

use constant PRIMARY_KEY => 'address';

mk_accessors(qw(address staking_key_id owner_pubkeyhash));

my $DELEGATIONS;
my $HASHES;

sub list {
    my $class = shift // __PACKAGE__;
    $DELEGATIONS //= [ $class->find() ];
    return @$DELEGATIONS;
}

sub get_by_hash {
    my $class = shift;
    my ($scripthash) = @_;
    if (!$HASHES) {
        $HASHES = { map { $_->scripthash => $_ } $class->list };
    }
    return $HASHES->{$scripthash};
}

sub staking_key {
    my $self = shift;
    return $self->{staking_key} //= do {
        my ($key) = grep { $_->id == $self->staking_key_id } QBitcoin::StakingKey->list;
        $key or die "No staking key for delegation " . $self->address . "\n";
    };
}

sub scripthash {
    my $self = shift;
    return $self->{scripthash} //= scripthash_by_address($self->address);
}

sub redeem_script {
    my $self = shift;
    return delegation_script($self->owner_pubkeyhash, $self->staking_key->pubkeyhash);
}

sub create {
    my $class = shift;
    my ($staking_key, $owner_pubkeyhash) = @_;
    my $address = delegation_address($owner_pubkeyhash, $staking_key->pubkeyhash);
    if (my ($existing) = grep { $_->address eq $address } $class->list) {
        return $existing;
    }
    my $self = QBitcoin::ORM::create($class, {
        address          => $address,
        staking_key_id   => $staking_key->id,
        owner_pubkeyhash => $owner_pubkeyhash,
    });
    if ($self) {
        Infof("Created delegation address %s", $address);
        push @$DELEGATIONS, $self if $DELEGATIONS;
        $HASHES->{$self->scripthash} = $self if $HASHES;
        # Do not forget to load utxo for this address by QBitcoin::Generate->load_address_utxo()
    }
    return $self;
}

sub remove {
    my $self = shift;
    my $scripthash = $self->scripthash;
    $self->delete;
    @$DELEGATIONS = grep { $_ != $self } @$DELEGATIONS if $DELEGATIONS;
    delete $HASHES->{$scripthash} if $HASHES;
    # Re-add with the remaining roles: the owner key of the same address may be
    # in this wallet too
    foreach my $utxo (QBitcoin::Wallet::UTXO::myutxo_delegated()) {
        next unless $utxo->scripthash eq $scripthash;
        QBitcoin::Wallet::UTXO::myutxo_del($utxo);
        if (my $roles = $utxo->my_roles) {
            QBitcoin::Wallet::UTXO::myutxo_add($utxo, $roles);
        }
    }
    Warningf("Removed delegation address %s", $self->address);
    return;
}

1;
