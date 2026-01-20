#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Const;
BEGIN { no warnings 'redefine'; *QBitcoin::Const::MAX_EMPTY_TX_IN_BLOCK = sub () { 100 } };
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Test::Send qw(send_block send_tx send_raw_tx $last_tx);
use QBitcoin::Test::Tokens qw(send_tokens_tx);
use QBitcoin::Config;
use QBitcoin::Address qw(address_by_hash);
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::Utils qw(tokens_balance tokens_received all_tokens_balance get_tokens_txs);

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });
$config->{regtest} = 1;

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { $_[0]->{min_tx_time} = $_[0]->{min_tx_block_height} = -1; return 0; });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

blockchain_synced(1);

# height, hash, prev_hash, weight, $tx
send_block(0, "a0", undef, 50, send_tx());
send_block(1, "a1", "a0", 100, send_tx());

my $data_mint = TOKEN_TXO_TYPE_PERMISSIONS . pack("C", TOKEN_PERMISSION_MINT);
my $data_transfer = TOKEN_TXO_TYPE_TRANSFER . pack("Q<", 1000);
my $create_contract = send_tokens_tx(undef, [ $data_mint, $data_transfer, $data_transfer, $data_transfer, $data_transfer ]);
ok($create_contract, "Created token contract");

# increase funds without mint permission
my $tx_fail1 = send_tokens_tx($create_contract->hash, [ TOKEN_TXO_TYPE_TRANSFER . pack("Q<", 3000) ], [ $create_contract->out->[1] ]);
ok(!$tx_fail1, "Failed to increase funds without mint permission");
# increase funds with mint permission
my $tx_ok1 = send_tokens_tx($create_contract->hash, [ TOKEN_TXO_TYPE_TRANSFER . pack("Q<", 3000) ], [ $create_contract->out->[1], $create_contract->out->[0] ]);
ok($tx_ok1, "Increased funds with mint permission");
# create mint permission without permission
my $tx_fail2 = send_tokens_tx($create_contract->hash, [ TOKEN_TXO_TYPE_PERMISSIONS . pack("C", TOKEN_PERMISSION_MINT) ], [ $create_contract->out->[2] ]);
ok(!$tx_fail2, "Failed to create mint permission without permission");
# spent (input) with standard tx
my $out = QBitcoin::TXO->new_txo({
    value      => 0,
    num        => 0,
    scripthash => $create_contract->out->[2]->scripthash,
    data       => TOKEN_TXO_TYPE_TRANSFER . pack("Q<", 5000),
});
$create_contract->out->[2]->{redeem_script} = $SCRIPT{$create_contract->out->[2]->scripthash};
my $tx_ok2 = QBitcoin::Transaction->new({
    in      => [ { txo => $create_contract->out->[2], siglist => [] } ],
    out     => [ $out ],
    fee     => 0,
    tx_type => TX_TYPE_STANDARD,
});
$tx_ok2->calculate_hash();
$tx_ok2->out->[0]->tx_in = $tx_ok2->hash;
ok(send_raw_tx($tx_ok2), "Create standard tx which spends tokens");
# use standard tx output as token input
my $tx_fail3 = send_tokens_tx($create_contract->hash, [ TOKEN_TXO_TYPE_TRANSFER . pack("Q<", 5000) ], [ $tx_ok2->out->[0] ]);
ok(!$tx_fail3, "Failed to use standard tx output as token input");
# spend with another token_id
my $create_contract2 = send_tokens_tx(undef, [ $data_transfer, $data_transfer ]);
my $tx_fail4 = send_tokens_tx($create_contract2->hash, [ TOKEN_TXO_TYPE_TRANSFER . pack("Q<", 2000) ], [ $create_contract2->out->[0], $create_contract->out->[2] ]);
ok(!$tx_fail4, "Spent with another token_id");
my @out = (
    QBitcoin::TXO->new_txo({
        value      => 0,
        num        => 0,
        scripthash => $create_contract2->out->[0]->scripthash,
        data       => TOKEN_TXO_TYPE_TRANSFER . pack("Q<", 600),
    }),
    QBitcoin::TXO->new_txo({
        value      => 0,
        num        => 0,
        scripthash => $create_contract->out->[1]->scripthash,
        data       => TOKEN_TXO_TYPE_TRANSFER . pack("Q<", 400),
    }),
);
my $tx_ok3 = QBitcoin::Transaction->new({
    in         => [ { txo => $create_contract2->out->[0], siglist => [] } ],
    out        => \@out,
    fee        => 0,
    tx_type    => TX_TYPE_TOKENS,
    token_hash => $create_contract2->hash,
});
$tx_ok3->calculate_hash();
$tx_ok3->out->[0]->tx_in = $tx_ok3->out->[1]->tx_in = $tx_ok3->hash;
ok(send_raw_tx($tx_ok3), "Send tokens with second contract");

# output with incorrect data length
# second spend for $create_contract->out->[2], it's ok for mempool
my $tx_ok4 = send_tokens_tx($create_contract->hash, [ TOKEN_TXO_TYPE_TRANSFER . pack("Q<", 2000) . "extra" ], [ $create_contract->out->[2] ]);
ok($tx_ok4, "Created tx with incorrect data length");
# Now:
# $create_contract: -> A1(1000,1000,1000,1000)
# $tx_ok1: A1(1000) -> A2(3000)
# $tx_ok2: A1(1000) -> A1(burn-5000) (standard tx)
# $tx_ok4: A1(1000) -> A3(burn-2000) (incorrect data length)
# get_tokens_txs
# amount and received by database
my $address1 = address_by_hash($create_contract->out->[1]->scripthash);
is(tokens_balance($address1, $create_contract->hash, 0), 2000, "Balance on first address");
is(tokens_balance(address_by_hash($tx_ok1->out->[0]->scripthash), $create_contract->hash, 0), 3000, "Balance on second address");
is(tokens_balance(address_by_hash($tx_ok3->out->[0]->scripthash), $create_contract->hash, 0), 0, "Balance on third address");
is(tokens_balance(address_by_hash($create_contract2->out->[0]->scripthash), $create_contract2->hash, 0), 1600, "Balance on contract2");
is(tokens_balance($address1, $create_contract2->hash, 0), 400, "Balance on contract2");
is(tokens_received($address1, $create_contract->hash, 0), 4000, "Received on first address");
my $balance = all_tokens_balance($address1, 0);
is_deeply($balance, { $create_contract->hash => 2000, $create_contract2->hash => 400 }, "All tokens balance");

# confirm transactions
ok(send_block(2, "a2", "a1", 150, $create_contract, $tx_ok1, $tx_ok2), "Confirm transactions");
my ($txs_chain, $txs_mempool) = get_tokens_txs($address1, $create_contract->hash);
is_deeply($txs_chain, [[ $tx_ok2->hash, -1000, 2 ], [ $tx_ok1->hash, -1000, 2 ], [ $create_contract->hash, 4000, 2 ]], "Get tokens txs from chain");
$txs_mempool->[0]->[2] = undef; # do not check tx received_time for mempool
is_deeply($txs_mempool, [[ $tx_ok4->hash, -1000, undef ]], "Get tokens txs from mempool");

# check balance after confirmation
is(tokens_balance($address1, $create_contract->hash, 0), 2000, "Balance on first address");
is(tokens_balance(address_by_hash($tx_ok1->out->[0]->scripthash), $create_contract->hash, 0), 3000, "Balance on second address");
is(tokens_balance(address_by_hash($tx_ok3->out->[0]->scripthash), $create_contract->hash, 0), 0, "Balance on third address");
is(tokens_balance(address_by_hash($create_contract2->out->[0]->scripthash), $create_contract2->hash, 0), 1600, "Balance on contract2");
is(tokens_balance($address1, $create_contract2->hash, 0), 400, "Balance on contract2");
is(tokens_received($address1, $create_contract->hash, 0), 4000, "Received on first address");

# store blocks and transactions to the database
send_block(3, "a3", "a2", 200, send_tx(0, undef));
send_block(4, "a4", "a3", 250, send_tx());
send_block(5, "a5", "a4", 300, send_tx());
send_block(6, "a6", "a5", 350, send_tx());
send_block(7, "a7", "a6", 400, send_tx());
send_block(8, "a8", "a7", 450, send_tx());
send_block(9, "a9", "a8", 500, send_tx());
QBitcoin::Block->store_blocks();
QBitcoin::Block->cleanup_old_blocks();
ok(QBitcoin::Block->min_incore_height > 2, "Transactions stored in database");

# check balance by database
is(tokens_balance($address1, $create_contract->hash, 0), 2000, "Balance on first address");
is(tokens_balance(address_by_hash($tx_ok1->out->[0]->scripthash), $create_contract->hash, 0), 3000, "Balance on second address");
is(tokens_received($address1, $create_contract->hash, 0), 4000, "Received on first address");
my $balance2 = all_tokens_balance($address1, 0);
is_deeply($balance2, { $create_contract->hash => 2000, $create_contract2->hash => 400 }, "All tokens balance");
my ($txs2_chain, $txs2_mempool) = get_tokens_txs($address1, $create_contract->hash);
is_deeply($txs2_chain, [[ $tx_ok2->hash, -1000, 2 ], [ $tx_ok1->hash, -1000, 2 ], [ $create_contract->hash, 4000, 2 ]], "Get tokens txs from chain");

done_testing();
