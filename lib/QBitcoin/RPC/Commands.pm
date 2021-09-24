package QBitcoin::RPC::Commands;
use warnings;
use strict;

use Role::Tiny;
use List::Util qw(sum0 sum min max);
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::ORM qw(dbh);
use QBitcoin::Block;
use QBitcoin::Coinbase;
use QBitcoin::Transaction;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced btc_synced);
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Address qw(scripthash_by_address);
use QBitcoin::Protocol;
use QBitcoin::ConnectionList;
use Bitcoin::Serialized;
use Bitcoin::Block;

my %PARAMS;
my %HELP;

sub params { $PARAMS{$_[1]} }
sub help   { $HELP{$_[1]}   }

$PARAMS{ping} = "";
$HELP{ping} = qq(
Check that the node alive and responsible.

Result:
null    (json null)

Examples:
> qbitcoin-cli ping
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "ping", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_ping {
    my $self = shift;
    $self->response_ok;
}

$PARAMS{getblockchaininfo} = "";
$HELP{getblockchaininfo} = qq(
Returns an object containing various state info regarding blockchain processing.

Result:
{                                         (json object)
  "chain" : "str",                        (string) current network name (main, test, regtest)
  "blocks" : n,                           (numeric) the height of the most-work fully-validated chain. The genesis block has height 0
  "bestblockhash" : "str",                (string) the hash of the currently best block
  "weight" : n,                           (numeric) the current weight
  "mediantime" : n,                       (numeric) median time for the current best block
  "initialblockdownload" : true|false,    (boolean) (debug information) estimate of whether this node is in Initial Block Download mode
  "total_coins" : n,                      (numeric) total number of generated (upgraded) coins
  "btc_headers" : n,                      (numeric) number of processed btc block headers
  "btc_scanned" : n,                      (numeric) number of scanned btc blocks
  "btc_synced" : true|false,              (bookean) is btc blockchain fully synced or is in initial block download mode
}

Examples:
> qbitcoin-cli getblockchaininfo
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockchaininfo", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getblockchaininfo {
    my $self = shift;
    my $best_block;
    if (defined(my $height = QBitcoin::Block->blockchain_height)) {
        $best_block = QBitcoin::Block->best_block($height);
    }
    my $response = {
        chain                => "main",
        blocks               => $best_block ? $best_block->height+0   : -1,
        bestblockhash        => $best_block ? unpack("H*", $best_block->hash) : undef,
        weight               => $best_block ? $best_block->weight+0   : -1,
        initialblockdownload => blockchain_synced() ? FALSE : TRUE,
        # size_on_disk         => # TODO
    };
    $response->{headers} = $response->{blocks}; # satisfy explorers
    if (UPGRADE_POW) {
        my ($btc_block) = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 1);
        my $btc_scanned;
        if ($btc_block) {
            if ($btc_block->scanned) {
                $btc_scanned = $btc_block;
            }
            else {
                ($btc_scanned) = Bitcoin::Block->find(scanned => 1, -sortby => 'height DESC', -limit => 1);
            }
        }
        $response->{btc_synced}  = btc_synced() ? TRUE : FALSE,
        $response->{btc_headers} = $btc_block   ? $btc_block->height+0   : 0,
        $response->{btc_scanned} = $btc_scanned ? $btc_scanned->height+0 : 0,
        my ($coinbase) = dbh->selectrow_array("SELECT SUM(value) FROM `" . QBitcoin::Coinbase->TABLE . "` WHERE tx_out IS NOT NULL");
        $response->{total_coins} = $coinbase ? $coinbase / DENOMINATOR : 0;
    }
    return $self->response_ok($response);
}

$PARAMS{getbestblockhash} = "";
$HELP{getbestblockhash} = qq(
Returns the hash of the best (tip) block in the most-weight fully-validated chain.

Result:
"hex"    (string) the block hash, hex-encoded

Examples:
> qbitcoin-cli getbestblockhash
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getbestblockhash", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getbestblockhash {
    my $self = shift;
    my $best_block;
    if (defined(my $height = QBitcoin::Block->blockchain_height)) {
        $best_block = QBitcoin::Block->best_block($height);
    }
    return $self->response_ok($best_block ? unpack("H*", $best_block->hash) : undef);
}

$PARAMS{help} = "command?";
$HELP{help} = q(
List all commands, or get help for a specified command.

Arguments:
1. command    (string, optional, default=all commands) The command to get help on

Result:
"str"    (string) The help text
);
sub cmd_help {
    my $self = shift;
    if (my $cmd = $self->args->[0]) {
        if (defined $self->params($cmd)) {
            return $self->response_ok($self->brief($cmd) . "\n" . ($HELP{$cmd} // ""));
        }
        else {
            return $self->response_ok("help: unknown command: $cmd");
        }
    }
    my $help = "";
    foreach my $cmd (sort keys %PARAMS) {
        $help .= $self->brief($cmd) . "\n";
    }
    return $self->response_ok($help);
}

$PARAMS{getblockheader} = "blockhash";
$HELP{getblockheader} = qq(
Returns an Object with information about blockheader <hash>.

Arguments:
1. blockhash    (string, required) The block hash

Result:
{                                 (json object)
  "hash" : "hex",                 (string) the block hash (same as provided)
  "confirmations" : n,            (numeric) The number of confirmations, or -1 if the block is not on the main chain
  "height" : n,                   (numeric) The block height or index
  "merkleroot" : "hex",           (string) The merkle root
  "time" : xxx,                   (numeric) The block time expressed in UNIX epoch time
  "nTx" : n,                      (numeric) The number of transactions in the block
  "previousblockhash" : "hex",    (string) The hash of the previous block
  "nextblockhash" : "hex"         (string) The hash of the next block
}

Examples:
> qbitcoin-cli getblockheader "00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockheader", "params": ["00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getblockheader {
    my $self = shift;
    my $hash = pack("H*", $self->args->[0]);
    my $best_height = QBitcoin::Block->blockchain_height;
    my $block = $self->get_block_by_hash($hash)
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Block not found");
    my $best_block = QBitcoin::Block->best_block($best_height);
    my $next_block = QBitcoin::Block->best_block($block->height + 1) // QBitcoin::Block->find(height => $block->height + 1);

    return $self->response_ok({
        hash              => unpack("H*", $block->hash),
        height            => $block->height,
        time              => time_by_height($block->height),
        confirmations     => $best_height - $block->height,
        nTx               => scalar(@{$block->transactions}),
        previousblockhash => unpack("H*", $block->prev_hash),
        nextblockhash     => $next_block ? unpack("H*", $next_block->hash) : undef,
        merkleroot        => unpack("H*", $block->merkle_root),
        weight            => $block->weight,
        confirm_weight    => $best_block->weight - $block->weight,
    });
}

$PARAMS{getblockcount} = "";
$HELP{getblockcount} = qq(
Returns the height of the most-work fully-validated chain.
The genesis block has height 0.

Result:
n    (numeric) The current block count

Examples:
> qbitcoin-cli getblockcount
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockcount", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getblockcount {
    my $self = shift;
    return $self->response_ok(QBitcoin::Block->blockchain_height);
}

$PARAMS{getblock} = "blockhash verbosity?";
$HELP{getblock} = qq(
If verbosity is 1, returns an Object with information about block <hash>.
If verbosity is 2, returns an Object with information about block <hash> and information about each transaction.

Arguments:
1. blockhash    (string, required) The block hash
2. verbosity    (numeric, optional, default=1) 1 for a json object, and 2 for json object with transaction data

Result (for verbosity = 1):
{                                 (json object)
  "hash" : "hex",                 (string) the block hash (same as provided)
  "confirmations" : n,            (numeric) The number of confirmations, or -1 if the block is not on the main chain
  "size" : n,                     (numeric) The block size
  "weight" : n,                   (numeric) The block weight
  "height" : n,                   (numeric) The block height or index
  "merkleroot" : "hex",           (string) The merkle root
  "tx" : [                        (json array) The transaction ids
    "hex",                        (string) The transaction id
    ...
  ],
  "time" : xxx,                   (numeric) The block time expressed in UNIX epoch time
  "nTx" : n,                      (numeric) The number of transactions in the block
  "previousblockhash" : "hex",    (string) The hash of the previous block
  "nextblockhash" : "hex"         (string) The hash of the next block
}

Result (for verbosity = 2):
{             (json object)
  ...,        Same output as verbosity = 1
  "tx" : [    (json array)
    {         (json object)
      ...     The transactions in the format of the getrawtransaction RPC. Different from verbosity = 1 "tx" result
    },
    ...
  ]
}

Examples:
> qbitcoin-cli getblock "00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblock", "params": ["00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getblock {
    my $self = shift;
    my $hash = pack("H*", $self->args->[0]);
    my $verbosity = $self->args->[1] // 1;

    my $best_height = QBitcoin::Block->blockchain_height;
    my $block = $self->get_block_by_hash($hash)
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Block not found");
    my $best_block = QBitcoin::Block->best_block($best_height);
    my $next_block = QBitcoin::Block->best_block($block->height + 1) // QBitcoin::Block->find(height => $block->height + 1);

    my $res = {
        hash              => unpack("H*", $block->hash),
        height            => $block->height,
        time              => time_by_height($block->height),
        confirmations     => $best_height - $block->height,
        previousblockhash => unpack("H*", $block->prev_hash),
        nextblockhash     => $next_block ? unpack("H*", $next_block->hash) : undef,
        merkleroot        => unpack("H*", $block->merkle_root),
        weight            => $block->weight,
        confirm_weight    => $best_block->weight - $block->weight,
    };
    if ($verbosity == 1) {
        $res->{tx} = [ map { unpack("H*", $_) } @{$block->tx_hashes} ];
    }
    else {
        $res->{tx} = [ map { $_->as_hashref } @{$block->transactions} ];
    }

    return $self->response_ok($res);
}

$PARAMS{getblockhash} = "height";
$HELP{getblockhash} = qq(
Returns hash of block in best-block-chain at height provided.

Arguments:
1. height    (numeric, required) The height index

Result:
"hex"    (string) The block hash

Examples:
> bitcoin-cli getblockhash 1000
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockhash", "params": [1000]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT()}/
);
sub cmd_getblockhash {
    my $self = shift;
    my $height = $self->args->[0];
    my $block = QBitcoin::Block->best_block($height) // QBitcoin::Block->find(height => $height);
    if (!$block) {
        return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Block not found");
    }
    return $self->response_ok(unpack("H*", $block->hash));
}

$PARAMS{getrawtransaction} = "txid verbose?";
$HELP{getrawtransaction} = qq(
getrawtransaction "txid" ( verbose )

Return the raw transaction data.

If verbose is 'true', returns an Object with information about 'txid'.
If verbose is 'false' or omitted, returns a string that is serialized, hex-encoded data for 'txid'.

Arguments:
1. txid         (string, required) The transaction id
2. verbose      (boolean, optional, default=true) If false, return a string, otherwise return a json object

Result (if verbose is set false):
"str"    (string) The serialized, hex-encoded data for 'txid'

Result (if verbose is not set or is set to true):
{                                    (json object)
  "hash" : "hex",                    (string) The transaction hash (differs from txid for witness transactions)
  "size" : n,                        (numeric) The serialized transaction size
  "vin" : [                          (json array)
    {                                (json object)
      "txid" : "hex",                (string) The transaction id
      "vout" : n,                    (numeric) The output number
      "scriptSig" : {                (json object) The script
        "hex" : "hex"                (string) hex
      },
    },
    ...
  ],
  "vout" : [                         (json array)
    {                                (json object)
      "value" : n,                   (numeric) The value in BTC
      "n" : n,                       (numeric) index
      "scriptPubKey" : {             (json object)
        "hex" : "str",               (string) the hex
        "reqSigs" : n,               (numeric) The required sigs
        "type" : "str",              (string) The type, eg 'pubkeyhash'
        "addresses" : [              (json array)
          "str",                     (string) bitcoin address
          ...
        ]
      }
    },
    ...
  ],
  "blockhash" : "hex",               (string) the block hash
  "confirmations" : n,               (numeric) The confirmations
  "blocktime" : xxx,                 (numeric) The block time expressed in UNIX epoch time
  "time" : n                         (numeric) Same as "blocktime"
}

Examples:
> qbitcoin-cli getrawtransaction "mytxid"
> qbitcoin-cli getrawtransaction "mytxid" true
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getrawtransaction", "params": ["mytxid", true]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getrawtransaction {
    my $self = shift;
    my $hash = pack("H*", $self->args->[0]);
    my $verbose = $self->args->[1] // TRUE;
    my $tx = QBitcoin::Transaction->get_by_hash($hash);
    if (!$tx) {
        return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "No such mempool or blockchain transaction");
    }
    if (!$verbose) {
        return $self->response_ok(unpack("H*", $tx->serialize));
    }

    my $res = $tx->as_hashref;
    if (defined $tx->block_height) {
        my $best_height = QBitcoin::Block->blockchain_height;
        $res->{confirmations} = $best_height - $tx->block_height;
        $res->{blocktime} = time_by_height($tx->block_height);
        my $block = QBitcoin::Block->best_block($tx->block_height) // QBitcoin::Block->find(height => $tx->block_height);
        if ($block) {
            my $best_block = QBitcoin::Block->best_block($best_height);
            $res->{confirm_weight} = $best_block->weight - $block->weight;
            $res->{blockhash} = unpack("H*", $block->hash);
        }
    }
    else {
        $res->{confirmations} = -1;
        $res->{confirm_weight} = -1;
    }
    return $self->response_ok($res);
}

$PARAMS{createrawtransaction} = "inputs outputs";
$HELP{createrawtransaction} = qq(
createrawtransaction [{"txid":"hex","vout":n},...] [{"address":amount},...]

Create a transaction spending the given inputs and creating new outputs.
Outputs can be addresses or data.
Returns hex-encoded raw transaction.
Note that the transaction's inputs are not signed, and
it is not stored in the wallet or transmitted to the network.

Arguments:
1. inputs                      (json array, required) The inputs
     [
       {                       (json object)
         "txid": "hex",        (string, required) The transaction id
         "vout": n,            (numeric, required) The output number
       },
       ...
     ]
2. outputs                     (json array, required) The outputs (key-value pairs)
     [
       {                       (json object)
         "address": amount,    (numeric or string, required) A key-value pair. The key (string) is the bitcoin address, the value (float or string) is the amount in BTC
       },
       ...
     ]

Result:
"hex"    (string) hex string of the transaction

Examples:
> bitcoin-cli createrawtransaction '[{"txid":"myid","vout":0}]' '[{"address":0.01}]'
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "createrawtransaction", "params": ['[{"txid":"myid","vout":0}]', '[{"address":0.01}]"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_createrawtransaction {
    my $self = shift;
    my $inputs  = $self->args->[0];
    my $outputs = $self->args->[1];
    my @in  = map {{ txo => QBitcoin::TXO->new_txo(tx_in => pack("H*", $_->{txid}), num => $_->{vout}+0) }} @$inputs;
    my @out;
    foreach my $out (@$outputs) {
        push @out, map { QBitcoin::TXO->new_txo(value => $out->{$_} * DENOMINATOR, scripthash => scripthash_by_address($_)) } keys %$out;
    }
    my $tx = QBitcoin::Transaction->new(
        in  => \@in,
        out => \@out,
    );
    return $self->response_ok(unpack("H*", $tx->serialize_unsigned));
}

$PARAMS{sendrawtransaction} = "hexstring";
$HELP{sendrawtransaction} = qq(
sendrawtransaction "hexstring"

Submit a raw transaction (serialized, hex-encoded) to local node and network.

Also see createrawtransaction and signrawtransactionwithkey calls.

Arguments:
1. hexstring     (string, required) The hex string of the raw transaction

Result:
"hex"    (string) The transaction hash in hex

Examples:

Create a transaction
> bitcoin-cli createrawtransaction "[{\"txid\" : \"mytxid\",\"vout\":0}]" "{\"myaddress\":0.01}"
Sign the transaction, and get back the hex
> bitcoin-cli signrawtransactionwithwallet "myhex"

Send the transaction (signed hex)
> bitcoin-cli sendrawtransaction "signedhex"

As a JSON-RPC call
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "sendrawtransaction", "params": ["signedhex"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_sendrawtransaction {
    my $self = shift;
    my $data = Bitcoin::Serialized->new(pack("H*", $self->args->[0]));
    my $tx = QBitcoin::Transaction->deserialize($data);
    if (!$tx || $data->length) {
        return $self->response_error("", ERR_DESERIALIZATION_ERROR, "TX decode failed.");
    }
    $tx->received_from = $self;
    if (QBitcoin::Transaction->has_pending($tx->hash)) {
        return $self->response_error("", ERR_VERIFY_ALREADY_IN_CHAIN, "Transaction already published.");
    }
    if (QBitcoin::Transaction->check_by_hash($tx->hash)) {
        return $self->response_error("", ERR_VERIFY_ALREADY_IN_CHAIN, "Transaction already published.");
    }
    if (!$tx->load_txo()) {
        return $self->response_error("", ERR_DESERIALIZATION_ERROR, "Incorrect transaction data.");
    }
    if ($tx->is_pending) {
        return $self->response_error("", ERR_VERIFY_ALREADY_IN_CHAIN, "Some inputs unknown.");
    }
    if ($self->process_tx($tx) != 0) {
        return $self->response_error("", ERR_VERIFY_ALREADY_IN_CHAIN, "Transaction failed.");
    }
    return $self->response_ok(unpack("H*", $tx->hash));
}

$PARAMS{signrawtransactionwithkey} = "hexstring privatekeys";
$HELP{signrawtransactionwithkey} = qq(
signrawtransactionwithkey "hexstring" ["privatekey",...]

Sign inputs for raw transaction (serialized, hex-encoded).
The second argument is an array of base58-encoded private
keys that will be the only keys used to sign the transaction.

Arguments:
1. hexstring                        (string, required) The transaction hex string
2. privkeys                         (json array, required) The base58-encoded private keys for signing
     [
       "privatekey",                (string) private key in base58-encoding
       ...
     ]

Result:
{                             (json object)
  "hex" : "hex",              (string) The hex-encoded raw transaction with signature(s)
  "complete" : true|false,    (boolean) If the transaction has a complete set of signatures
  "errors" : [                (json array, optional) Script verification errors (if there are any)
    {                         (json object)
      "txid" : "hex",         (string) The hash of the referenced, previous transaction
      "vout" : n,             (numeric) The index of the output to spent and used as input
      "scriptSig" : "hex",    (string) The hex-encoded signature script
      "error" : "str"         (string) Verification or signing error related to the input
    },
    ...
  ]
}

Examples:
> bitcoin-cli signrawtransactionwithkey "myhex" "[\"key1\",\"key2\"]"
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "signrawtransactionwithkey", "params": ["myhex", "[\"key1\",\"key2\"]"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_signrawtransactionwithkey {
    my $self = shift;
    my $data = Bitcoin::Serialized->new(pack("H*", $self->args->[0]));
    my $privkeys = $self->args->[1];
    my $tx = QBitcoin::Transaction->deserialize($data);
    if (!$tx || $data->length) {
        return $self->response_error("", ERR_DESERIALIZATION_ERROR, "TX decode failed.");
    }
    $tx->received_from = $self;
    if (!$tx->load_inputs()) {
        return $self->response_error("", ERR_DESERIALIZATION_ERROR, "Incorrect transaction data.");
    }
    if ($tx->is_pending) {
        return $self->response_error("", ERR_DESERIALIZATION_ERROR, "Some inputs unknown.");
    }
    if ($tx->is_known) {
        return $self->response_error("", ERR_VERIFY_ALREADY_IN_CHAIN, "Transaction already published.");
    }
    my @address = map { QBitoin::MyAddress->new(private_key => $_) } @$privkeys;
    my @errors;
    foreach my $num (0 .. $#{$tx->in}) {
        my $in = $tx->in->[$num];
        my ($address, $script);
        foreach my $addr (@address) {
            if ($script = $addr->script_by_hash($in->{txo}->scripthash)) {
                $address = $addr;
                last;
            }
        }
        if ($address) {
            $tx->make_sign($in, $address, $num);
        }
        else {
            push @errors, {
                txid       => $in->{txo}->tx_in,
                vout       => $in->{txo}->num,
                scripthash => $in->{txo}->scripthash,
                error      => "Unknown scripthash",
            };
        }
    }
    $tx->calculate_hash;
    return $self->response_ok({
        hex      => unpack("H*", $tx->serialize_unsigned),
        complete => @errors ? FALSE : TRUE,
        errors   => \@errors,
    });
}

$PARAMS{decoderawtransaction} = "hexstring";
$HELP{decoderawtransaction} = qq(
decoderawtransaction "hexstring"

Return a JSON object representing the serialized, hex-encoded transaction.

Arguments:
1. hexstring    (string, required) The transaction hex string

Result:
{                           (json object)
  "txid" : "hex",           (string) The transaction id
  "size" : n,               (numeric) The transaction size
  "weight" : n,             (numeric) The transaction's weight (between vsize*4 - 3 and vsize*4)
  "vin" : [                 (json array)
    {                       (json object)
      "txid" : "hex",       (string) The transaction id
      "vout" : n,           (numeric) The output number
      "script" : {          (json object) The script
        "hex" : "hex"       (string) hex
      },
    },
    ...
  ],
  "vout" : [                (json array)
    {                       (json object)
      "value" : n,          (numeric) The amount
      "n" : n,              (numeric) index
      "address" : "str"     (string) address
    },
    ...
  ]
}

Examples:
> bitcoin-cli decoderawtransaction "hexstring"
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "decoderawtransaction", "params": ["hexstring"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_decoderawtransaction {
    my $self = shift;
    my $data = Bitcoin::Serialized->new(pack("H*", $self->args->[0]));

    my $tx = QBitcoin::Transaction->deserialize($data);
    if (!$tx || $data->length) {
        return $self->response_error("", ERR_DESERIALIZATION_ERROR, "TX decode failed.");
    }
    return $self->response_ok($tx->as_hashref);
}

$PARAMS{getmempoolinfo} = "";
$HELP{getmempoolinfo} = qq(
getmempoolinfo

Returns details on the active state of the TX memory pool.

Result:
{                            (json object)
  "loaded" : true|false,     (boolean) True if the mempool is fully loaded
  "size" : n,                (numeric) Current tx count
  "bytes" : n,               (numeric) Sum of all transaction sizes
}

Examples:
> bitcoin-cli getmempoolinfo
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getmempoolinfo", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getmempoolinfo {
    my $self = shift;

    my @mempool = QBitcoin::Transaction->mempool_list();
    return $self->response_ok({
        loaded => mempool_synced() ? TRUE : FALSE,
        size   => scalar(@mempool),
        bytes  => sum0(map { $_->size } @mempool),
    });
}

$PARAMS{getrawmempool} = "verbose?";
$HELP{getrawmempool} = qq(
getrawmempool ( verbose )

Returns all transaction ids in memory pool as a json array of string transaction ids.

Arguments:
1. verbose             (boolean, optional, default=false) True for a json object, false for array of transaction ids

Result (for verbose = false):
[           (json array)
  "hex",    (string) The transaction id
  ...
]

Result (for verbose = true):
{                                         (json object)
  "transactionid" : {                     (json object)
    "size" : n,                           (numeric) transaction size
    "fee" : n,                            (numeric) transaction fee
    "time" : xxx,                         (numeric) local time transaction entered pool in seconds since 1 Jan 1970 GMT
  },
  ...
}

Examples:
> bitcoin-cli getrawmempool true
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getrawmempool", "params": [true]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getrawmempool {
    my $self = shift;
    my $verbose = $self->args->[0] // FALSE;

    return $self->response_ok([ map { $verbose ? $_->as_hashref : unpack("H*", $_->hash) } QBitcoin::Transaction->mempool_list() ]);
}

$PARAMS{validateaddress} = "address";
$HELP{validateaddress} = qq(
validateaddress "address"

Return information about the given bitcoin address.

Arguments:
1. address    (string, required) The address to validate

Result:
{                               (json object)
  "isvalid" : true|false,       (boolean) If the address is valid or not. If not, this is the only property returned.
  "address" : "str",            (string) The bitcoin address validated
  "scriptHash" : "hex",         (string) The hex-encoded scriptHash generated by the address
}

Examples:
> bitcoin-cli validateaddress "WMAdVHijSynNwkU4RCttKhavrohAz2tNPvBPLF"
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "validateaddress", "params": ["WMAdVHijSynNwkU4RCttKhavrohAz2tNPvBPLF"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_validateaddress {
    my $self = shift;
    my $address = $self->args->[0] // FALSE;

    my $scripthash = eval { scripthash_by_address($address) };
    if ($scripthash) {
        return $self->response_ok({ isvalid => TRUE, address => $address, scripthash => unpack("H*", $scripthash) });
    }
    else {
        return $self->response_ok({ isvalid => FALSE });
    }
}

$PARAMS{getnetworkinfo} = "";
$HELP{getnetworkinfo} = qq(
getnetworkinfo
Returns an object containing various state info regarding P2P networking.

Result:
{                                                    (json object)
  "version" : n,                                     (numeric) the server version
  "protocolversion" : n,                             (numeric) the protocol version
  "connections" : n,                                 (numeric) the total number of connections
  "connections_in" : n,                              (numeric) the number of inbound connections
  "connections_out" : n,                             (numeric) the number of outbound connections
  "networkactive" : true|false,                      (boolean) whether p2p networking is enabled
  "networks" : [                                     (json array) information per network
    {                                                (json object)
      "name" : "str",                                (string) network (ipv4, ipv6 or onion)
      "limited" : true|false,                        (boolean) is the network limited using -onlynet?
      "reachable" : true|false,                      (boolean) is the network reachable?
      "proxy" : "str",                               (string) ("host:port") the proxy that is used for this network, or empty if none
      "proxy_randomize_credentials" : true|false     (boolean) Whether randomized credentials are used
    },
    ...
  ],
}

Examples:
> bitcoin-cli getnetworkinfo
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getnetworkinfo", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getnetworkinfo {
    my $self = shift;
    my $connect_in = 0;
    my $connect_out = 0;
    foreach my $connection (grep { $_->type_id == PROTOCOL_QBITCOIN } QBitcoin::ConnectionList->list()) {
        $connection->direction == DIR_IN ? $connect_in++ : $connect_out++;
    }
    return $self->response_ok({
        version         => VERSION,
        subversion      => "/QBitcoinCore:0.1/",
        protocolversion => QBitcoin::Protocol->PROTOCOL_VERSION,
        connections_in  => $connect_in,
        connections_out => $connect_out,
        connections     => $connect_in + $connect_out,
        networkactive   => TRUE,
        networks        => [{
            name      => "ipv4",
            reachable => TRUE,
        }],
    });
}

# Just to satisfy btc explorer
$PARAMS{getindexinfo} = "";
$HELP{getindexinfo} = qq(
getindexinfo

Returns the status of all available indices currently running in the node.

Result:
{                               (json object)
  "name" : {                    (json object) The name of the index
    "synced" : true|false,      (boolean) Whether the index is synced or not
    "best_block_height" : n     (numeric) The block height to which the index is synced
  }
}

Examples:
> bitcoin-cli getindexinfo
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getindexinfo", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getindexinfo {
    my $self = shift;
    return $self->response_ok({
        txindex => {
            synced => TRUE,
        },
    });
}

$PARAMS{getchaintxstats} = "nblocks? blockhash?";
$HELP{getchaintxstats} = qq(
getchaintxstats ( nblocks "blockhash" )

Compute statistics about the total number and rate of transactions in the chain.

Arguments:
1. nblocks      (numeric, optional, default=one month) Size of the window in number of blocks
2. blockhash    (string, optional, default=chain tip) The hash of the block that ends the window.

Result:
{                                       (json object)
  "time" : xxx,                         (numeric) The timestamp for the final block in the window, expressed in UNIX epoch time
  "txcount" : n,                        (numeric) The total number of transactions in the chain up to that point
  "window_final_block_hash" : "hex",    (string) The hash of the final block in the window
  "window_final_block_height" : n,      (numeric) The height of the final block in the window.
  "window_block_count" : n,             (numeric) Size of the window in number of blocks
  "window_tx_count" : n,                (numeric) The number of transactions in the window. Only returned if "window_block_count" is > 0
  "window_interval" : n,                (numeric) The elapsed time in the window in seconds. Only returned if "window_block_count" is > 0
  "txrate" : n                          (numeric) The average rate of transactions per second in the window. Only returned if "window_interval" is > 0
}

Examples:
> bitcoin-cli getchaintxstats
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getchaintxstats", "params": [2016]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getchaintxstats {
    my $self = shift;
    my $nblocks = $self->args->[0] // 30*24*3600/BLOCK_INTERVAL;
    my $last_block;
    if (my $blockhash = $self->args->[1]) {
        $last_block = $self->get_block_by_hash(pack("H*", $blockhash))
            or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Block not found");
    }
    else {
        my $best_height = QBitcoin::Block->blockchain_height;
        $last_block = QBitcoin::Block->best_block($best_height)
            or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Block not found");
    }
    my $start_height = $last_block->height - $nblocks + 1;
    $start_height = 0 if $start_height < 0;
    # TODO: count via QBitcoin::Transaction->fetch(..., -func => { count => 'count(*)' });
    my ($count) = dbh->selectrow_array(
        "SELECT COUNT(*) FROM `" . QBitcoin::Transaction->TABLE . "` WHERE block_height >= ? AND block_height <= ?",
        undef, $start_height, $last_block->height);

    return $self->response_ok({
        time                      => time_by_height($last_block->height),
        window_final_block_hash   => unpack("H*", $last_block->hash),
        window_final_block_height => $last_block->height,
        window_block_count        => $last_block->height - $start_height + 1,
        window_tx_count           => $count,
        window_interval           => ($last_block->height - $start_height) * BLOCK_INTERVAL,
        $last_block->height > $start_height ? ( txrate => $count * BLOCK_INTERVAL / ($last_block->height - $start_height) ) : (),
    });
}

$PARAMS{getblockstats} = "hash_or_height";
$HELP{getblockstats} = qq(
getblockstats hash_or_height

Compute per block statistics for a given window. All amounts are in satoshis.

Arguments:
1. hash_or_height    (string or numeric, required) The block hash or height of the target block

Result:
{                              (json object)
  "avgfee" : n,                (numeric) Average fee in the block
  "avgfeerate" : n,            (numeric) Average feerate (in satoshis per virtual byte)
  "avgtxsize" : n,             (numeric) Average transaction size
  "blockhash" : "hex",         (string) The block hash (to check for potential reorgs)
  "feerate_percentiles" : [    (json array) Feerates at the 10th, 25th, 50th, 75th, and 90th percentile weight unit (in satoshis per virtual byte)
    n,                         (numeric) The 10th percentile feerate
    n,                         (numeric) The 25th percentile feerate
    n,                         (numeric) The 50th percentile feerate
    n,                         (numeric) The 75th percentile feerate
    n                          (numeric) The 90th percentile feerate
  ],
  "height" : n,                (numeric) The height of the block
  "ins" : n,                   (numeric) The number of inputs (excluding coinbase)
  "maxfee" : n,                (numeric) Maximum fee in the block
  "maxfeerate" : n,            (numeric) Maximum feerate (in satoshis per virtual byte)
  "maxtxsize" : n,             (numeric) Maximum transaction size
  "medianfee" : n,             (numeric) Truncated median fee in the block
  "mediantime" : n,            (numeric) The block median time past
  "mediantxsize" : n,          (numeric) Truncated median transaction size
  "minfee" : n,                (numeric) Minimum fee in the block
  "minfeerate" : n,            (numeric) Minimum feerate (in satoshis per virtual byte)
  "mintxsize" : n,             (numeric) Minimum transaction size
  "outs" : n,                  (numeric) The number of outputs
  "subsidy" : n,               (numeric) The block subsidy
  "time" : n,                  (numeric) The block time
  "total_out" : n,             (numeric) Total amount in all outputs (excluding coinbase and thus reward [ie subsidy + totalfee])
  "total_size" : n,            (numeric) Total size of all non-coinbase transactions
  "total_weight" : n,          (numeric) Total weight of all non-coinbase transactions
  "totalfee" : n,              (numeric) The fee total
  "txs" : n,                   (numeric) The number of transactions (including coinbase)
  "utxo_increase" : n,         (numeric) The increase/decrease in the number of unspent outputs
  "utxo_size_inc" : n          (numeric) The increase/decrease in size for the utxo index (not discounting op_return and similar)
}

Examples:
> bitcoin-cli getblockstats '"00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"'
> bitcoin-cli getblockstats 1000
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockstats", "params": ["00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockstats", "params": [1000]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getblockstats {
    my $self = shift;
    my $hash_or_height = $self->args->[0];

    my $block;
    if (length($hash_or_height) == 64) {
        $block = $self->get_block_by_hash(pack("H*", $hash_or_height));
    }
    else {
        $block = QBitcoin::Block->best_block($hash_or_height) // QBitcoin::Block->find(height => $hash_or_height);
    }
    $block or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Block not found");
    my @tx = sort { $a->fee/$a->size <=> $b->fee/$b->size } grep { $_->fee >= 0 } @{$block->transactions};
    my $res = {
        blockhash  => unpack("H*", $block->hash),
        height     => $block->height,
        ins        => sum0(map { scalar @{$_->in} } @{$block->transactions}),
        outs       => sum0(map { scalar @{$_->out} } @{$block->transactions}),
        subsidy    => 0,
        time       => time_by_height($block->height),
        total_out  => sum0(map { $_->value } map { @{$_->out} } @{$block->transactions}),
        total_size => sum0(map { $_->size } @{$block->transactions}),
        txs        => scalar(@{$block->transactions}),
        totalfee   => 0,
    };
    $res->{utxo_increase} = $res->{outs} - $res->{ins};
    if (@tx) {
        $res->{avgfee}       = sum(map { $_->fee } @tx) / @tx;
        $res->{avgfeerate}   = sum(map { $_->fee/$_->size } @tx) / @tx;
        $res->{avgtxsize}    = sum(map { $_->size } @{$block->transactions}) / @{$block->transactions};
        $res->{maxfee}       = max(map { $_->fee } @tx);
        $res->{maxfeerate}   = $tx[-1]->fee/$tx[-1]->size;
        $res->{maxtxsize}    = max(map { $_->size } @{$block->transactions});
        $res->{medianfee}    = (sort { $a->fee <=> $b->fee } @tx)[@tx/2]->fee;
        $res->{mediantxsize} = (sort { $a->size <=> $b->size } @{$block->transactions})[@{$block->transactions}/2]->size;
        $res->{minfee}       = min(map { $_->fee } @tx);
        $res->{minfeerate}   = $tx[0]->fee/$tx[0]->size;
        $res->{mintxsize}    = min(map { $_->size } @{$block->transactions});
        $res->{subsidy}      = -$block->transactions->[0]->fee;
        $res->{totalfee}     = -$block->transactions->[0]->fee;
        $res->{feerate_percentiles} = [ map { $tx[@tx*$_/100]->fee/$tx[@tx*$_/100]->size } qw(10 25 50 75 90) ];
    }
    return $self->response_ok($res);
}

$PARAMS{getmempoolentry} = "txid verbose?";
$HELP{getmempoolentry} = qq(
getmempoolentry "txid"

Returns mempool data for given transaction

Arguments:
1. txid    (string, required) The transaction id (must be in mempool)

Result:
{                                       (json object)
  "size" : n,                           (numeric) virtual transaction size as defined in BIP 141. This is different from actual serialized size for witness transactions as witness data is discounted.
  "fee" : n,                            (numeric) transaction fee in BTC (DEPRECATED)
  "time" : xxx,                         (numeric) local time transaction entered pool in seconds since 1 Jan 1970 GMT
}

Examples:
> bitcoin-cli getmempoolentry "mytxid"
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getmempoolentry", "params": ["mytxid"]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getmempoolentry {
    my $self = shift;
    my $hash = pack("H*", $self->args->[0]);
    my $verbose = $self->args->[1] // TRUE;
    my $tx = QBitcoin::Transaction->get($hash)
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "No such mempool");
    return $self->response_ok($tx->as_hashref);
}

# getmemoryinfo
# getrpcinfo
# stop
# uptime

# addnode
# clearbanned
# disconnectnode
# getaddednodeinfo
# getconnectioncount
# getpeerinfo
# listbanned
# setban

# signmessagewithprivkey
# verifymessage
# getaddressinfo

# listreceivedbyaddress
# getreceivedbyaddress
# listunspentbyaddress
# listtransactions

# listmyaddresses
# getbalance
# listunspent
# importprivkey
# dumpprivkey

1;
