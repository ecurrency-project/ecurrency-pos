#! /usr/bin/env perl
use warnings;
use strict;

# Spending transactions for the outputs of a transaction: RPC gettxspendingprevout.
# Both confirmed (stored in the database) and mempool spends must be reported,
# a confirmed spend takes precedence.

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use Cpanel::JSON::XS;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::Send qw(send_block send_tx);
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Config;
use QBitcoin::Block;
use QBitcoin::TXO;
use QBitcoin::Transaction;

$config->{regtest} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
my $txo_module = Test::MockModule->new('QBitcoin::TXO');
$txo_module->mock('check_script', sub { 0 });
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('static_reward', sub { 0 });

# Minimal RPC handler for testing cmd_* without the HTTP layer (see rpc-address-peer.t)
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

# Validate params and call an RPC command; returns the TestRPC object for inspecting the result
sub rpc {
    my ($cmd, @args) = @_;
    my $rpc = TestRPC->new;
    $rpc->cmd($cmd);
    $rpc->args(\@args);
    $rpc->validate(TestRPC->params($cmd)) == 0
        or return undef;
    my $func = "cmd_$cmd";
    $rpc->$func;
    return $rpc;
}

sub txid { unpack("H*", $_[0]->hash) }

# Block 0: coinbase A; block 1: B spends A:0 (confirmed spend)
my $tx_a = send_tx(0, undef);
send_block(0, "a0", undef, 1, $tx_a);
my $tx_b = send_tx(0, $tx_a);
send_block(1, "a1", "a0", 52, $tx_b);
# Enough blocks on top to get A and B stored to the database and freed from memory
my $tx_last;
foreach my $height (2 .. 10) {
    $tx_last = send_tx(0, undef);
    send_block($height, "a$height", "a" . ($height-1), 50 + $height*2, $tx_last);
}
QBitcoin::Block->store_blocks();
QBitcoin::Block->cleanup_old_blocks();
ok(!QBitcoin::Transaction->get($tx_b->hash), "stored transaction is freed from memory");

# Mempool: C spends B:0 (B is loaded from the database for that)
my $loaded_b = QBitcoin::Transaction->get_by_hash($tx_b->hash)
    or die "Can't load stored transaction B\n";
my $tx_c = send_tx(0, $loaded_b);
ok(QBitcoin::Transaction->get($tx_c->hash), "mempool transaction C accepted");
undef $loaded_b;

my ($a, $b, $c, $last) = map { txid($_) } $tx_a, $tx_b, $tx_c, $tx_last;

my $rpc = rpc('gettxspendingprevout', [ { txid => $a, vout => 0 }, { txid => $b, vout => 0 }, { txid => $c, vout => 0 }, { txid => $last, vout => 0 } ]);
ok($rpc && !$rpc->_rpc_error, "gettxspendingprevout ok") or diag($rpc && $rpc->_rpc_error);
is_deeply($rpc && $rpc->_rpc_result, [
    { txid => $a,    vout => 0, spendingtxid => $b }, # confirmed spend, both stored in the database
    { txid => $b,    vout => 0, spendingtxid => $c }, # mempool spend of a stored output
    { txid => $c,    vout => 0 },                      # unspent mempool output
    { txid => $last, vout => 0 },                      # unspent confirmed output
], "spending transactions reported for stored, mempool and unspent outputs");

# JSON-encoded array as qbitcoin-cli passes it
$rpc = rpc('gettxspendingprevout', Cpanel::JSON::XS->new->encode([ { txid => $b, vout => "0" } ]));
is_deeply($rpc && $rpc->_rpc_result, [ { txid => $b, vout => 0, spendingtxid => $c } ], "json string param");

# Errors
$rpc = rpc('gettxspendingprevout', [ { txid => "00" x 32, vout => 0 } ]);
is($rpc && $rpc->_rpc_error_code, ERR_INVALID_ADDRESS_OR_KEY, "unknown transaction");
$rpc = rpc('gettxspendingprevout', [ { txid => $b, vout => 1 } ]);
is($rpc && $rpc->_rpc_error_code, ERR_INVALID_PARAMS, "output index out of range");
ok(!rpc('gettxspendingprevout'),                                  "missing param rejected");
ok(!rpc('gettxspendingprevout', []),                              "empty list rejected");
ok(!rpc('gettxspendingprevout', [ { txid => $b } ]),              "missing vout rejected");
ok(!rpc('gettxspendingprevout', [ { txid => "xx", vout => 0 } ]), "bad txid rejected");

done_testing();
