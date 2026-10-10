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
#
# A delegation is registered either by the operator (adddelegationaddress RPC,
# /wallet/delegation/add REST) or, with the accept_delegations config option,
# from the chain itself (register_output): the owner funds the covenant
# address with an output whose data field is TXO_DATA_DELEGATION followed by
# the owner pubkeyhash. The address commits to both keys, so such an output
# on it is proof enough of the owner's intent, and no request to the delegate
# node is needed at all.

use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::ORM qw(find delete :types);
use QBitcoin::Address qw(scripthash_by_address);
use QBitcoin::Script::Delegation qw(delegation_script delegation_scripthash delegation_address);
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

# Minimum value (coins) of an output registering a delegation from the chain
# (config min_delegation): smaller outputs are ignored, so that dust cannot
# fill the delegation table and the stake transaction inputs
use constant MIN_DELEGATION_DEFAULT => 1;

# Days an address stays registered with no coins on it (config
# delegation_expire): the owner spent the coins away, or an operator added an
# address never funded. The registration is cheap to redo (a marked output or
# adddelegationaddress), so the table does not keep dead rows forever
use constant DELEGATION_EXPIRE_DEFAULT => 30;

my $DELEGATIONS;
my $HASHES;
my @PENDING_LOAD; # delegations registered from the chain whose UTXO are not loaded yet

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

# Register a delegation from a confirmed output marked with
# TXO_DATA_DELEGATION . owner_pubkeyhash in its data field (see the header).
# Called by Transaction::confirm for every confirmed output, before its is_my
# check, so that the registering output itself goes to the delegated UTXO
# right away. Cheap for an ordinary output: a length test on the data field.
# Returns the new delegation, or undef when the output registers nothing.
sub register_output {
    my $class = shift;
    my ($txo) = @_;
    $config->{accept_delegations}
        or return undef;
    my $data = $txo->data // "";
    (length($data) == 21 || length($data) == 33) && substr($data, 0, 1) eq TXO_DATA_DELEGATION
        or return undef;
    my @keys = QBitcoin::StakingKey->list
        or return undef;
    return undef if $class->get_by_hash($txo->scripthash); # already registered
    my $owner_pubkeyhash = substr($data, 1);
    my ($staking_key) = grep { delegation_scripthash($owner_pubkeyhash, $_->pubkeyhash) eq $txo->scripthash } @keys
        or return undef; # marked for another delegate, or a bogus mark
    my $min_value = int(($config->{min_delegation} // MIN_DELEGATION_DEFAULT) * DENOMINATOR + 0.5);
    if ($txo->value < $min_value) {
        Infof("Ignore delegation registration by output %s:%u: %lu coins is less than minimum %lu",
            $txo->tx_in_str, $txo->num, $txo->value, $min_value);
        return undef;
    }
    if (my $max = $config->{max_delegations}) {
        if ($class->list >= $max) {
            Warningf("Ignore delegation registration by output %s:%u: max_delegations %u reached",
                $txo->tx_in_str, $txo->num, $max);
            return undef;
        }
    }
    my $self = $class->create($staking_key, $owner_pubkeyhash)
        or return undef;
    Infof("Registered delegation address %s by output %s:%u", $self->address, $txo->tx_in_str, $txo->num);
    # The address may already have outputs: funded before the marked one, or
    # earlier in the same block. Loading them needs the chain lookup, which lives
    # above this module (Generate::load_address_utxo); Generate picks the
    # registered delegations up from here before building a stake
    push @PENDING_LOAD, $self;
    return $self;
}

# Delegations registered by register_output since the last call; the caller
# loads their UTXO
sub take_pending_load {
    my $class = shift;
    my @pending = splice(@PENDING_LOAD);
    return @pending;
}

# Remove the delegations whose address has had no tracked coins for
# delegation_expire days. The empty period is counted in memory from the
# moment the address is seen empty (the last output spent, or the startup
# load found none), so a restart starts it over; good enough for a cleanup.
# Returns the removed delegations.
sub expire_empty {
    my $class = shift;
    my ($now) = @_;
    $now //= time();
    my $expire = ($config->{delegation_expire} // DELEGATION_EXPIRE_DEFAULT) * 24 * 3600;
    my @removed;
    foreach my $delegation ($class->list) { # list() returns a copy, remove() is safe inside
        if (QBitcoin::Wallet::UTXO::myutxo_delegated_count($delegation->scripthash)) {
            delete $delegation->{empty_since};
        }
        elsif (!defined($delegation->{empty_since})) {
            $delegation->{empty_since} = $now;
        }
        elsif ($now - $delegation->{empty_since} >= $expire) {
            Infof("Delegation address %s has no coins for %u days, remove it",
                $delegation->address, ($now - $delegation->{empty_since}) / (24 * 3600));
            $delegation->remove;
            push @removed, $delegation;
        }
    }
    return @removed;
}

sub reset_cache {
    my $class = shift;
    undef $HASHES;
    undef $DELEGATIONS;
}

1;
