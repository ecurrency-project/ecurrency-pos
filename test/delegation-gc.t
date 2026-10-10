#! /usr/bin/env perl
use warnings;
use strict;

# Cleanup of the delegated-staking addresses: an address with no tracked
# coins is removed after delegation_expire days, counted from the moment it
# is seen empty and restarted when it is funded again; the max_delegations
# limit of the registrations from the chain.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::TXO;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format pubkeyhash_by_pubkey);
use QBitcoin::Script::Delegation qw(delegation_scripthash);
use QBitcoin::StakingKey;
use QBitcoin::Delegation;
use QBitcoin::Wallet::UTXO ();
use QBitcoin::Generate;

$config->{regtest} = 1;
$config->{accept_delegations} = 1;

my $staking_pk = generate_keypair(CRYPT_ALGO_ECDSA);
my $staking_key = QBitcoin::StakingKey->create({
    private_key => wallet_import_format($staking_pk->pk_serialize),
    pubkey      => $staking_pk->pubkey_by_privkey,
    algo        => CRYPT_ALGO_ECDSA,
});
sub owner_pkh { pubkeyhash_by_pubkey(generate_keypair(CRYPT_ALGO_ECDSA)->pubkey_by_privkey, CRYPT_ALGO_ECDSA) }
my $tx_num = 0;
sub fund {
    my ($delegation, $value) = @_;
    my $txo = QBitcoin::TXO->new_txo(value => $value, num => 0, tx_in => "tx" . ++$tx_num, scripthash => $delegation->scripthash);
    $txo->add_my_utxo;
    return $txo;
}
sub addresses { [ sort map { $_->address } QBitcoin::Delegation->list ] }

my $day = 24 * 3600;
my $t0  = 1_000_000_000;

my $empty  = QBitcoin::Delegation->create($staking_key, owner_pkh());
my $funded = QBitcoin::Delegation->create($staking_key, owner_pkh());
my $utxo   = fund($funded, 100);
is(QBitcoin::Wallet::UTXO::myutxo_delegated_count($funded->scripthash), 1, "funded address has one tracked output");
is(QBitcoin::Wallet::UTXO::myutxo_delegated_count($empty->scripthash), 0, "empty address has none");

# The empty period starts when the address is seen empty
is_deeply([ QBitcoin::Delegation->expire_empty($t0) ], [], "first pass: nothing removed");
is_deeply([ QBitcoin::Delegation->expire_empty($t0 + 29 * $day) ], [], "29 days: still kept");
is_deeply([ map { $_->address } QBitcoin::Delegation->expire_empty($t0 + 30 * $day) ], [ $empty->address ],
    "30 days: the empty address removed");
is_deeply(addresses(), [ $funded->address ], "the funded one stays");
is(scalar(my @rows = QBitcoin::Delegation->find()), 1, "removed from the database too");

# Spending the last output starts the period; funding again resets it
$utxo->del_my_utxo;
is(QBitcoin::Wallet::UTXO::myutxo_delegated_count($funded->scripthash), 0, "spent: no tracked outputs");
my $t1 = $t0 + 40 * $day;
is_deeply([ QBitcoin::Delegation->expire_empty($t1) ], [], "seen empty: period started");
fund($funded, 100);
is_deeply([ QBitcoin::Delegation->expire_empty($t1 + 10 * $day) ], [], "funded again: period reset");
(QBitcoin::Wallet::UTXO::myutxo_delegated())[0]->del_my_utxo;
is_deeply([ QBitcoin::Delegation->expire_empty($t1 + 20 * $day) ], [], "empty again: a new period");
is_deeply([ QBitcoin::Delegation->expire_empty($t1 + 31 * $day) ], [], "11 days of the new period: kept");
is_deeply([ map { $_->address } QBitcoin::Delegation->expire_empty($t1 + 50 * $day) ], [ $funded->address ],
    "30 days of the new period: removed");
is_deeply(addresses(), [], "no delegations left");

# Configurable period
$config->{delegation_expire} = 2;
my $short = QBitcoin::Delegation->create($staking_key, owner_pkh());
QBitcoin::Delegation->expire_empty($t0);
is_deeply([ QBitcoin::Delegation->expire_empty($t0 + 1 * $day) ], [], "delegation_expire 2: kept after a day");
is_deeply([ map { $_->address } QBitcoin::Delegation->expire_empty($t0 + 2 * $day) ], [ $short->address ],
    "delegation_expire 2: removed after two days");
delete $config->{delegation_expire};

# max_delegations limits the registrations from the chain, not the operator's
sub marked_txo {
    my $owner_pkh = owner_pkh();
    return QBitcoin::TXO->new_txo(
        value      => 2 * DENOMINATOR,
        num        => 0,
        tx_in      => "mark" . ++$tx_num,
        scripthash => delegation_scripthash($owner_pkh, $staking_key->pubkeyhash),
        data       => TXO_DATA_DELEGATION . $owner_pkh,
    );
}
$config->{max_delegations} = 2;
ok(QBitcoin::Delegation->register_output(marked_txo()), "first registration");
ok(QBitcoin::Delegation->register_output(marked_txo()), "second registration");
ok(!QBitcoin::Delegation->register_output(marked_txo()), "third refused: max_delegations reached");
is(scalar(QBitcoin::Delegation->list), 2, "two delegations");
ok(QBitcoin::Delegation->create($staking_key, owner_pkh()), "the operator may add more");
(QBitcoin::Delegation->list)[0]->remove;
(QBitcoin::Delegation->list)[0]->remove;
ok(QBitcoin::Delegation->register_output(marked_txo()), "a freed slot is registered again");
delete $config->{max_delegations};

# The periodic cleanup loads the pending registrations before judging emptiness
is(scalar(QBitcoin::Delegation->take_pending_load), 3, "registrations pending the utxo load");
QBitcoin::Delegation->register_output(marked_txo());
QBitcoin::Generate->cleanup_delegations();
is(scalar(QBitcoin::Delegation->take_pending_load), 0, "cleanup drained the pending load");
QBitcoin::Generate->cleanup_delegations();
pass("a second cleanup within the period is a no-op");

done_testing();
