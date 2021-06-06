package QBitcoin::MyAddress;
use warnings;
use strict;
use feature 'state';

use QBitcoin::Config;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::ORM qw(find :types);
use QBitcoin::Crypto qw(hash160 pubkey_by_privkey pk_import);
use QBitcoin::Address qw(address_by_pubkey wif_to_pk);

use Exporter qw(import);
our @EXPORT_OK = qw(my_address);

use constant TABLE => 'my_address';

use constant FIELDS => {
    # address     => STRING,
    private_key => STRING,
    pubkey_crc  => STRING,
};

mk_accessors(keys %{&FIELDS});

sub my_address {
    my $class = shift // __PACKAGE__;
    state $address = [ $class->find() ];
    return wantarray ? @$address : $address->[0];
}

sub privkey {
    my $self = shift;
    return $self->{privkey} //= pk_import(wif_to_pk($self->private_key));
}

sub pubkey {
    my $self = shift;
    return $self->{pubkey} if $self->{pubkey};
    $self->privkey or return undef;
    return $self->{pubkey} = pubkey_by_privkey($self->privkey);
}

sub pubkey_hash {
    my $self = shift;
    return $self->{pubkey_hash} //= hash160($self->pubkey);
}

sub address {
    my $self = shift;
    return $self->{address} //= address_by_pubkey($self->pubkey);
}

sub get_by_script {
    my $class = shift;
    my ($script) = @_;
    state $my_scripts;
    if (!$my_scripts) {
        $my_scripts = {};
        foreach my $address (my_address()) {
            foreach my $script (QBitcoin::OpenScript->script_for_address($address->address)) {
                $my_scripts->{$script} = $address;
            }
        }
    }
    return $my_scripts->{$script};
}

1;
