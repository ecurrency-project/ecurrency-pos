#! /usr/bin/env perl
use warnings;
use strict;

# RPC commands: getaddressinfo, listmyaddresses (include_watchonly option),
# listpeers and resetpeer

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Config;
use QBitcoin::Crypto qw(generate_keypair);
use QBitcoin::Address qw(wallet_import_format addresses_by_pubkey scripthash_by_address);
use QBitcoin::MyAddress;
use QBitcoin::Peer;

$config->{regtest} = 1;

# Minimal RPC handler for testing cmd_* without the HTTP layer (see wallet-password.t)
{
    package TestRPC;
    use warnings;
    use strict;
    use QBitcoin::Accessors qw(mk_accessors);
    use Role::Tiny::With;
    with 'QBitcoin::RPC::Validate';
    with 'QBitcoin::RPC::Commands';
    mk_accessors(qw(cmd args _rpc_result _rpc_error _rpc_error_code));
    sub new { bless {}, shift }
    sub response_ok    { $_[0]->_rpc_result($_[1] // "ok"); 0 }
    sub response_error { $_[0]->_rpc_error($_[1]); $_[0]->_rpc_error_code($_[2]); -1 }
}

# Call an RPC command; returns the TestRPC object for inspecting the result
sub rpc {
    my ($cmd, @args) = @_;
    my $rpc = TestRPC->new;
    $rpc->cmd($cmd);
    $rpc->args(\@args);
    my $func = "cmd_$cmd";
    $rpc->$func;
    return $rpc;
}

# Run only the params validation for an RPC command; returns 0 if params are valid
sub validate {
    my ($cmd, @args) = @_;
    my $rpc = TestRPC->new;
    $rpc->cmd($cmd);
    $rpc->args(\@args);
    return $rpc->validate(TestRPC->params($cmd));
}

sub make_address {
    my ($algo) = @_;
    my $pk = generate_keypair($algo);
    my ($address) = addresses_by_pubkey($pk->pubkey_by_privkey, $algo);
    return (wallet_import_format($pk->pk_serialize), $address);
}

my ($wif, $address) = make_address(CRYPT_ALGO_ECDSA);
QBitcoin::MyAddress->create({ private_key => $wif, address => $address, algo => CRYPT_ALGO_ECDSA });
my (undef, $watch_address) = make_address(CRYPT_ALGO_ECDSA);
QBitcoin::MyAddress->create({ address => $watch_address });
my (undef, $foreign_address) = make_address(CRYPT_ALGO_ECDSA);

# getaddressinfo
my $info = rpc('getaddressinfo', $address)->_rpc_result;
is($info->{address},     $address,                                         "getaddressinfo: address");
is($info->{scripthash},  unpack("H*", scripthash_by_address($address)),    "getaddressinfo: scripthash");
is($info->{ismine},      JSON::XS::true,  "own address is mine");
is($info->{iswatchonly}, JSON::XS::false, "own address is not watch-only");
is($info->{staked},      JSON::XS::false, "own address is not staked");
is($info->{algo},        "ecdsa",         "own address algo");
ok($info->{pubkey},                       "own address pubkey is known");

rpc('stakeaddress', $address);
$info = rpc('getaddressinfo', $address)->_rpc_result;
is($info->{staked}, JSON::XS::true, "staked flag after stakeaddress");

rpc('setaddresstag', $watch_address, "exchange");
$info = rpc('getaddressinfo', $watch_address)->_rpc_result;
is($info->{ismine},      JSON::XS::false, "watch-only address is not mine");
is($info->{iswatchonly}, JSON::XS::true,  "watch-only address is watch-only");
is($info->{tag},         "exchange",      "watch-only address tag");

$info = rpc('getaddressinfo', $foreign_address)->_rpc_result;
is($info->{ismine},      JSON::XS::false, "foreign address is not mine");
is($info->{iswatchonly}, JSON::XS::false, "foreign address is not watch-only");
ok(!exists $info->{staked},               "no wallet info for foreign address");

my $bad = rpc('getaddressinfo', substr($address, 0, -1) . ($address =~ /1$/ ? "2" : "1"));
is($bad->_rpc_error_code, ERR_INVALID_ADDRESS_OR_KEY, "invalid address checksum rejected");

# listmyaddresses with include_watchonly
my $list = rpc('listmyaddresses')->_rpc_result;
ok($list->{$address},       "listmyaddresses: own address listed by default");
ok($list->{$watch_address}, "listmyaddresses: watch-only address listed by default");

$list = rpc('listmyaddresses', JSON::XS::false)->_rpc_result;
ok($list->{$address},        "listmyaddresses(false): own address listed");
ok(!$list->{$watch_address}, "listmyaddresses(false): watch-only address not listed");

is(validate('listmyaddresses'),          0, "listmyaddresses params: empty is valid");
is(validate('listmyaddresses', "false"), 0, "listmyaddresses params: boolean is valid");
is(validate('listmyaddresses', "xx"),   -1, "listmyaddresses params: non-boolean is invalid");

# listpeers / resetpeer
my $peer = QBitcoin::Peer->get_or_create(
    ip      => IPV6_V4_PREFIX . pack("C4", 10, 1, 2, 3),
    type_id => PROTOCOL_QBITCOIN,
    port    => 9555,
);
$peer->failed_connect() foreach 1 .. 3;

my ($listed) = grep { $_->{addr} eq "10.1.2.3:9555" } @{rpc('listpeers')->_rpc_result};
ok($listed, "listpeers: known peer listed") or BAIL_OUT("peer not listed");
is($listed->{protocol},        "QECurrency",    "listpeers: protocol");
is($listed->{failed_connects}, 3,               "listpeers: failed connects counted");
is($listed->{connected},       JSON::XS::false, "listpeers: not connected");
is($listed->{connect_allowed}, JSON::XS::false, "listpeers: in failed-connects backoff");
ok($listed->{last_fail_time},                   "listpeers: last fail time set");

my $reset = rpc('resetpeer', "10.1.2.3");
like($reset->_rpc_result, qr/^Reset failed connects for QECurrency peer 10\.1\.2\.3$/, "resetpeer: result message");
is($peer->failed_connects, 0,     "resetpeer: failed connects counter reset");
is($peer->last_fail_time,  undef, "resetpeer: last fail time cleared");
ok($peer->is_connect_allowed,     "resetpeer: outgoing connection allowed again");

is(rpc('resetpeer', "10.9.9.9")->_rpc_error_code, ERR_INVALID_ADDRESS_OR_KEY, "resetpeer: unknown peer");

is(validate('resetpeer'),              -1, "resetpeer params: node is mandatory");
is(validate('resetpeer', "10.1.2.3"),   0, "resetpeer params: ip is valid");
is(validate('resetpeer', "node.example.com"), 0, "resetpeer params: hostname is valid");
is(validate('resetpeer', "bad host"),  -1, "resetpeer params: space is invalid");
is(validate('listpeers'),               0, "listpeers params: empty is valid");
is(validate('getaddressinfo', $address), 0, "getaddressinfo params: address is valid");
is(validate('getaddressinfo'),         -1, "getaddressinfo params: address is mandatory");

ok(TestRPC->readonly('getaddressinfo'), "getaddressinfo is read-only");
ok(TestRPC->readonly('listpeers'),      "listpeers is read-only");
ok(!TestRPC->readonly('resetpeer'),     "resetpeer is not read-only (runs in the main process)");

done_testing();
