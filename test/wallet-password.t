#! /usr/bin/env perl
use warnings;
use strict;

# RPC wallet commands: setwalletpassword (set / change / policy convergence /
# forgotten-password reset), walletunlock, walletlock, getwalletinfo,
# dumpprivkey and importprivkey password handling.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey);
use QBitcoin::MyAddress;
use QBitcoin::Password;
use QBitcoin::Wallet;
use QBitcoin::Generate::Control;

$config->{regtest} = 1;
$config->{allow_dumpprivkey} = 1;

# Minimal RPC handler for testing cmd_* without the HTTP layer (see createrawtransaction.t)
{
    package TestRPC;
    use warnings;
    use strict;
    use QBitcoin::Accessors qw(mk_accessors);
    use Role::Tiny::With;
    with 'QBitcoin::RPC::Commands';
    mk_accessors(qw(cmd args auth_password force _rpc_result _rpc_error _rpc_error_code));
    sub new { bless {}, shift }
    sub response_ok    { $_[0]->_rpc_result($_[1] // "ok"); 0 }
    sub response_error { $_[0]->_rpc_error($_[1]); $_[0]->_rpc_error_code($_[2]); -1 }
}

# Call a wallet RPC command; returns the TestRPC object for inspecting the result
sub rpc {
    my ($cmd, %opt) = @_;
    my $rpc = TestRPC->new;
    $rpc->cmd($cmd);
    $rpc->args($opt{args} // []);
    $rpc->auth_password($opt{password});
    $rpc->force($opt{force} ? 1 : 0);
    my $func = "cmd_$cmd";
    $rpc->$func;
    return $rpc;
}

sub make_address {
    my ($algo) = @_;
    my $pk = generate_keypair($algo);
    my $pubkey = $pk->pubkey_by_privkey;
    my ($address) = addresses_by_pubkey($pubkey, $algo);
    return (wallet_import_format($pk->pk_serialize), $address);
}

my ($wif1, $address1) = make_address(CRYPT_ALGO_ECDSA);
QBitcoin::MyAddress->create({ private_key => $wif1, address => $address1, algo => CRYPT_ALGO_ECDSA });
QBitcoin::Generate::Control->generate_enabled(1);

ok(TestRPC->requires_password('dumpprivkey'),    "dumpprivkey is gated by the wallet password");
ok(TestRPC->requires_password('walletunlock'),   "walletunlock is gated by the wallet password");
ok(!TestRPC->requires_password('getwalletinfo'), "getwalletinfo is not gated");

# Initial state
my $info = rpc('getwalletinfo')->_rpc_result;
is($info->{password_set},   JSON::XS::false, "no password initially");
is($info->{keys_encrypted}, JSON::XS::false, "keys not encrypted initially");
is($info->{locked},         JSON::XS::false, "not locked initially");
is($info->{staking_active}, JSON::XS::true,  "staking active initially");
is($info->{addresses},      1,               "one address");

# walletunlock / walletlock are no-ops without encryption
like(rpc('walletunlock')->_rpc_result, qr/not encrypted/, "walletunlock without encryption is a no-op");
like(rpc('walletlock')->_rpc_result,   qr/not encrypted/, "walletlock without encryption is a no-op");

# First password set encrypts the keys (default policy) and keeps the wallet unlocked
is(rpc('setwalletpassword', args => ["pass1"])->_rpc_result, "ok", "set the first password");
ok(QBitcoin::Wallet->is_encrypted, "keys encrypted");
$info = rpc('getwalletinfo')->_rpc_result;
is($info->{password_set},   JSON::XS::true,  "password set");
is($info->{keys_encrypted}, JSON::XS::true,  "keys encrypted in getwalletinfo");
is($info->{locked},         JSON::XS::false, "unlocked right after setting the password");
is($info->{staking_active}, JSON::XS::true,  "staking still active");

# dumpprivkey with the wallet unlocked (the generic password gate is emulated by
# the caller: in the real flow QBitcoin::RPC::process_request has already
# verified the top-level password field for gated commands)
is(rpc('dumpprivkey', args => [$address1])->_rpc_result, $wif1, "dumpprivkey with unlocked wallet");

# Lock: staking stops, dumpprivkey needs the password
is(rpc('walletlock')->_rpc_result, "ok", "walletlock");
$info = rpc('getwalletinfo')->_rpc_result;
is($info->{locked},         JSON::XS::true,  "locked");
is($info->{staking_active}, JSON::XS::false, "staking inactive while locked");
is(rpc('dumpprivkey', args => [$address1], password => "pass1")->_rpc_result, $wif1,
    "dumpprivkey decrypts with the password while locked");
ok(!QBitcoin::Wallet->unlocked, "dumpprivkey did not leave the wallet unlocked");
is(rpc('dumpprivkey', args => [$address1], password => "wrong")->_rpc_error_code, ERR_WALLET_PASSWORD_INCORRECT,
    "dumpprivkey with a wrong password fails");

# importprivkey requires an unlocked wallet when the keys are encrypted
my ($wif2, $address2) = make_address(CRYPT_ALGO_ECDSA);
is(rpc('importprivkey', args => [$wif2])->_rpc_error_code, ERR_WALLET_UNLOCK_NEEDED,
    "importprivkey fails on a locked wallet");

# walletunlock
is(rpc('walletunlock', password => "wrong")->_rpc_error_code, ERR_WALLET_PASSWORD_INCORRECT,
    "walletunlock with a wrong password fails");
is(rpc('walletunlock', password => "pass1")->_rpc_result, "ok", "walletunlock");
like(rpc('walletunlock', password => "pass1")->_rpc_result, qr/already unlocked/, "walletunlock is idempotent");
$info = rpc('getwalletinfo')->_rpc_result;
is($info->{locked},         JSON::XS::false, "unlocked");
is($info->{staking_active}, JSON::XS::true,  "staking active after unlock");

# importprivkey into the unlocked encrypted wallet stores the key encrypted
like(rpc('importprivkey', args => [$wif2])->_rpc_result, qr/^Private key for address \Q$address2\E imported$/,
    "importprivkey into the unlocked wallet, no plaintext warning");
my $row2 = QBitcoin::MyAddress->find(address => $address2);
ok(QBitcoin::Wallet->is_encrypted_pk($row2->private_key), "imported key stored encrypted");
ok($row2->pubkey, "imported key stored with pubkey");
is($row2->wif, $wif2, "imported key decrypts back");

# Password change: requires the old password
is(rpc('setwalletpassword', args => ["pass2"])->_rpc_error_code, ERR_WALLET_PASSWORD_REQUIRED,
    "password change without the old password asks for it");
is(rpc('setwalletpassword', args => ["pass2"], password => "wrong")->_rpc_error_code, ERR_WALLET_PASSWORD_INCORRECT,
    "password change with a wrong old password fails (no allow_password_reset)");
is(rpc('setwalletpassword', args => ["pass2"], password => "pass1")->_rpc_result, "ok", "password changed");
rpc('walletlock');
is(rpc('walletunlock', password => "pass1")->_rpc_error_code, ERR_WALLET_PASSWORD_INCORRECT, "old password does not unlock");
is(rpc('walletunlock', password => "pass2")->_rpc_result, "ok", "new password unlocks");

# Convergence to encrypted_private_keys=0 decrypts the keys (same password allowed)
$config->{encrypted_private_keys} = 0;
is(rpc('setwalletpassword', args => ["pass2"], password => "pass2")->_rpc_result, "ok", "converge to policy 0");
ok(!QBitcoin::Wallet->is_encrypted, "keys decrypted");
is(QBitcoin::MyAddress->find(address => $address1)->private_key, $wif1, "plaintext WIF back in the database");
$info = rpc('getwalletinfo')->_rpc_result;
is($info->{keys_encrypted}, JSON::XS::false, "not encrypted in getwalletinfo");
ok(!$info->{warning}, "no warning when the state matches the policy");

# importprivkey into an unencrypted wallet warns about plaintext storage
my ($wif3, $address3) = make_address(CRYPT_ALGO_ECDSA);
like(rpc('importprivkey', args => [$wif3])->_rpc_result, qr/stored unencrypted/,
    "importprivkey warns about unencrypted storage");

# Policy mismatch is reported by getwalletinfo
$config->{encrypted_private_keys} = 1;
like(rpc('getwalletinfo')->_rpc_result->{warning}, qr/unencrypted/, "warning on policy mismatch");
is(rpc('setwalletpassword', args => ["pass2"], password => "pass2")->_rpc_result, "ok", "converge back to policy 1");
ok(QBitcoin::Wallet->is_encrypted, "keys encrypted again");
is(QBitcoin::Wallet->encrypted_count, 3, "all three keys encrypted");

# Forgotten-password reset
rpc('walletlock');
$config->{allow_password_reset} = 0;
is(rpc('setwalletpassword', args => ["pass3"], password => "forgot")->_rpc_error_code, ERR_WALLET_PASSWORD_INCORRECT,
    "reset is refused without allow_password_reset");
$config->{allow_password_reset} = 1;
my $r = rpc('setwalletpassword', args => ["pass3"], password => "forgot");
is($r->_rpc_error_code, ERR_CONFIRMATION_REQUIRED, "reset asks for confirmation");
like($r->_rpc_error, qr/DESTROY 3 encrypted/, "confirmation message reports the number of destroyed keys");
is(rpc('setwalletpassword', args => ["pass3"], password => "forgot", force => 1)->_rpc_result, "ok", "forced reset");
ok(QBitcoin::Password->check_password("pass3"), "new password set by the reset");
ok(!QBitcoin::Wallet->is_encrypted, "no master key after the reset");
is(QBitcoin::MyAddress->find(address => $address1), undef, "encrypted keys destroyed");
is(rpc('getwalletinfo')->_rpc_result->{addresses}, 0, "no addresses left");

done_testing();
