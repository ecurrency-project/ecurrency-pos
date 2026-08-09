#! /usr/bin/env perl
use warnings;
use strict;

# REST API for delegated staking: staking keys, delegations, generating and
# importing delegation owner addresses, role reporting in my_addresses.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use HTTP::Request;
use HTTP::Response;
use Cpanel::JSON::XS;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::REST;
use QBitcoin::MyAddress;
use QBitcoin::StakingKey;
use QBitcoin::Delegation;

$config->{regtest} = 1;

my $JSON = Cpanel::JSON::XS->new;

my $sent;
my $rest_module = Test::MockModule->new('QBitcoin::REST');
$rest_module->mock('check_access', sub { undef });
$rest_module->mock('send', sub { $sent = $_[1]; 0 });

sub req {
    my ($method, $path, $body) = @_;
    my $request = HTTP::Request->new($method, "http://localhost$path");
    if (defined $body) {
        $request->header('Content-Type' => 'application/json');
        $request->content($JSON->encode($body));
    }
    $sent = undef;
    my $rest = bless {}, 'QBitcoin::REST';
    $rest->process_request($request);
    my $response = HTTP::Response->parse($sent);
    my $content = ($response->content_type // "") eq "application/json"
        ? $JSON->decode($response->content) : $response->content;
    return ($response->code, $content);
}

# --- Delegate side: staking key ---

my ($code, $res) = req(POST => "/wallet/staking_key/new");
is($code, 200, "staking_key/new ok");
ok($res->{pubkeyhash}, "staking key pubkeyhash returned");
my $staking_pkh = $res->{pubkeyhash};

($code, $res) = req(GET => "/wallet/staking_keys");
is($code, 200, "staking_keys ok");
is_deeply($res, [ { pubkeyhash => $staking_pkh, algo => "ecdsa", delegations => 0 } ], "staking_keys list");

# --- Owner side: new delegated address ---

($code, $res) = req(POST => "/wallet/my_address/new", { delegate_pubkeyhash => $staking_pkh });
is($code, 200, "my_address/new with delegate ok");
ok($res->{address} && $res->{private_key} && $res->{pubkeyhash}, "delegated address fields");
my ($deleg_address, $owner_wif, $owner_pkh) = @$res{qw(address private_key pubkeyhash)};

($code, $res) = req(POST => "/wallet/my_address/new");
is($code, 200, "plain my_address/new still works");
ok($res->{address} && $res->{private_key} && !$res->{pubkeyhash}, "plain address fields");

($code, $res) = req(POST => "/wallet/my_address/new", { delegate_pubkeyhash => "garbage" });
is($code, 400, "invalid delegate pubkeyhash rejected");

# --- Delegate side: register the delegation ---

($code, $res) = req(POST => "/wallet/delegation/add", { owner_pubkeyhash => $owner_pkh });
is($code, 200, "delegation/add ok");
is($res->{address}, $deleg_address, "delegation address matches the owner's");

($code, $res) = req(GET => "/wallet/delegations");
is($code, 200, "delegations ok");
is_deeply($res, [ {
    address            => $deleg_address,
    owner_pubkeyhash   => $owner_pkh,
    staking_pubkeyhash => $staking_pkh,
} ], "delegations list");

($code, $res) = req(GET => "/wallet/staking_keys");
is($res->[0]{delegations}, 1, "staking key delegation count");

($code, $res) = req(POST => "/wallet/delegation/add", { owner_pubkeyhash => "garbage" });
is($code, 400, "invalid owner pubkeyhash rejected");

# --- Owner key import on the same node (the "both" case) ---

($code, $res) = req(POST => "/wallet/my_address/add", { address => $deleg_address, private_key => $owner_wif });
is($code, 200, "delegation owner key imported");
is($res->{address}, $deleg_address, "imported address matches");

($code, $res) = req(GET => "/wallet/my_addresses");
my ($entry) = grep { $_->{address} eq $deleg_address } @$res;
ok($entry, "delegated address in my_addresses");
is($entry->{delegation}, "both", "role is both");
ok($entry->{staked}, "shown as staked (the delegation stakes it)");

# The staked flag cannot be toggled on a delegated address
($code, $res) = req(POST => "/wallet/my_address/$deleg_address/edit", { staked => 1 });
is($code, 400, "staking the owner address refused");

# --- Remove the delegation: the owner row remains ---

($code, $res) = req(POST => "/wallet/delegation/$deleg_address/remove");
is($code, 200, "delegation removed");
($code, $res) = req(GET => "/wallet/delegations");
is_deeply($res, [], "delegations empty");
($code, $res) = req(GET => "/wallet/my_addresses");
($entry) = grep { $_->{address} eq $deleg_address } @$res;
is($entry->{delegation}, "owner", "role is owner after the delegation removal");
ok(!$entry->{staked}, "not staked any more");

done_testing();
