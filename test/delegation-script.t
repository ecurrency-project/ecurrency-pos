#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;

use QBitcoin::Config;
use QBitcoin::Const;
use QBitcoin::Script qw(script_eval);
use QBitcoin::Script::Delegation qw(
    delegation_script delegation_scripthash delegation_address
    SELECTOR_OWNER SELECTOR_DELEGATE
);
use QBitcoin::Crypto qw(signature hash256 generate_keypair);
use QBitcoin::Address qw(
    wallet_import_format delegation_import_format wif_to_pk wif_delegation_hash
    validate_address pubkeyhash_str pubkeyhash_by_str
);
use QBitcoin::MyAddress;

$config->{debug} = 0;

my $owner_pk    = generate_keypair(CRYPT_ALGO_ECDSA);
my $delegate_pk = generate_keypair(CRYPT_ALGO_ECDSA);
my $owner    = QBitcoin::MyAddress->new( private_key => wallet_import_format($owner_pk->pk_serialize) );
my $delegate = QBitcoin::MyAddress->new( private_key => wallet_import_format($delegate_pk->pk_serialize) );
my $owner_hash    = hash256($owner->pubkey);
my $delegate_hash = hash256($delegate->pubkey);

my $script     = delegation_script($owner_hash, $delegate_hash);
my $scripthash = delegation_scripthash($owner_hash, $delegate_hash);
is($scripthash, hash256($script), "scripthash");
ok(validate_address(delegation_address($owner_hash, $delegate_hash)), "address valid");

my $sh_other  = "\x22" x 32;
my $sign_data = "\x55\xaa" x 700;
my $value     = 1 << 41; # exercise 64-bit script ints

# The owner spends the delegated coins to another address
my $tx_spend = TestTx->new(
    tx_type   => TX_TYPE_STANDARD,
    sign_data => $sign_data,
    in  => [ { txo => TestTxo->new(scripthash => $scripthash, value => $value) } ],
    out => [ TestTxo->new(scripthash => $sh_other, value => $value) ],
);
# The delegate stakes the coins: the principal returns to the same scripthash,
# the reward goes to the delegate's own address
my $tx_stake = TestTx->new(
    tx_type   => TX_TYPE_STAKE,
    sign_data => $sign_data,
    in  => [ { txo => TestTxo->new(scripthash => $scripthash, value => $value) } ],
    out => [
        TestTxo->new(scripthash => $scripthash, value => $value),
        TestTxo->new(scripthash => $sh_other,   value => 100),
    ],
);
# Theft attempt: part of the principal is redirected
my $tx_steal = TestTx->new(
    tx_type   => TX_TYPE_STAKE,
    sign_data => $sign_data,
    in  => [ { txo => TestTxo->new(scripthash => $scripthash, value => $value) } ],
    out => [
        TestTxo->new(scripthash => $scripthash, value => $value - 1),
        TestTxo->new(scripthash => $sh_other,   value => 1),
    ],
);

my $sig_owner    = signature($sign_data, $owner,    CRYPT_ALGO_ECDSA, SIGHASH_ALL);
my $sig_delegate = signature($sign_data, $delegate, CRYPT_ALGO_ECDSA, SIGHASH_ALL);
my $owner_branch    = [ $sig_owner,    $owner->pubkey,    SELECTOR_OWNER    ];
my $delegate_branch = [ $sig_delegate, $delegate->pubkey, SELECTOR_DELEGATE ];

ok( script_eval($owner_branch,    $script, $tx_spend, 0), "owner spends");
ok( script_eval($owner_branch,    $script, $tx_stake, 0), "owner stakes himself");
ok( script_eval($delegate_branch, $script, $tx_stake, 0), "delegate stakes");
ok(!script_eval($delegate_branch, $script, $tx_spend, 0), "delegate cannot spend");
ok(!script_eval($delegate_branch, $script, $tx_steal, 0), "delegate cannot steal");
ok(!script_eval([ $sig_delegate, $delegate->pubkey, SELECTOR_OWNER ], $script, $tx_spend, 0),
    "delegate key rejected in the owner branch");
ok(!script_eval([ $sig_owner, $owner->pubkey, SELECTOR_DELEGATE ], $script, $tx_stake, 0),
    "owner key rejected in the delegate branch");
ok(!script_eval([ $sig_delegate, $owner->pubkey, SELECTOR_DELEGATE ], $script, $tx_stake, 0),
    "signature must match the pubkey");

# Post-quantum delegate key: the script commits to hash256(pubkey), the full
# pubkey travels in the siglist and funds its own sigops budget
my $falcon_pk = generate_keypair(CRYPT_ALGO_FALCON);
my $falcon    = QBitcoin::MyAddress->new( private_key => wallet_import_format($falcon_pk->pk_serialize) );
my $falcon_hash    = hash256($falcon->pubkey);
my $script_pq      = delegation_script($owner_hash, $falcon_hash);
my $scripthash_pq  = delegation_scripthash($owner_hash, $falcon_hash);
my $tx_stake_pq = TestTx->new(
    tx_type   => TX_TYPE_STAKE,
    sign_data => $sign_data,
    in  => [ { txo => TestTxo->new(scripthash => $scripthash_pq, value => $value) } ],
    out => [ TestTxo->new(scripthash => $scripthash_pq, value => $value) ],
);
my $sig_falcon = signature($sign_data, $falcon, CRYPT_ALGO_FALCON, SIGHASH_ALL);
ok(script_eval([ $sig_falcon, $falcon->pubkey, SELECTOR_DELEGATE ], $script_pq, $tx_stake_pq, 0),
    "post-quantum delegate stakes");

# Delegation WIF: carries the private key and the delegate pubkeyhash
my $deleg_wif = delegation_import_format($owner_pk->pk_serialize, $delegate_hash);
is(wif_to_pk($deleg_wif), $owner_pk->pk_serialize, "wif_to_pk on delegation wif");
is(wif_delegation_hash($deleg_wif), $delegate_hash, "wif_delegation_hash");
is(wif_delegation_hash(wallet_import_format($owner_pk->pk_serialize)), undef, "plain wif has no delegation hash");
# A MyAddress object built from the delegation WIF signs as usual
my $owner2 = QBitcoin::MyAddress->new( private_key => $deleg_wif );
is($owner2->pubkey, $owner->pubkey, "pubkey from delegation wif");

# base58 pubkeyhash exchange format
my $pkh_str = pubkeyhash_str($delegate_hash);
is(pubkeyhash_by_str($pkh_str), $delegate_hash, "pubkeyhash_str round trip");
my $corrupted = $pkh_str;
substr($corrupted, 10, 1) = substr($corrupted, 10, 1) eq "2" ? "3" : "2";
ok(!eval { pubkeyhash_by_str($corrupted); 1 }, "corrupted pubkeyhash string rejected");
ok(!eval { pubkeyhash_by_str(delegation_address($owner_hash, $delegate_hash)); 1 }, "address rejected as pubkeyhash");

done_testing();

package TestTx;
use warnings;
use strict;
use QBitcoin::Accessors qw(new);
sub tx_type { $_[0]->{tx_type} }
sub in  { $_[0]->{in} }
sub out { $_[0]->{out} }
sub sign_data { $_[0]->{sign_data} }

package TestTxo;
use warnings;
use strict;
use QBitcoin::Accessors qw(new);
sub scripthash { $_[0]->{scripthash} }
sub value      { $_[0]->{value} }

1;
