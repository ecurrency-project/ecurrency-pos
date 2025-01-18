package QBitcoin::RPC::Commands;
use warnings;
use strict;

use Role::Tiny;
use List::Util qw(sum0 sum min max);
use QBitcoin::Const;
use QBitcoin::RPC::Const;
use QBitcoin::Config;
use QBitcoin::ORM qw(dbh);
use QBitcoin::Crypto qw(pk_import pk_alg generate_keypair);
use QBitcoin::Block;
use QBitcoin::Coinbase;
use QBitcoin::Transaction;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced btc_synced);
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Address qw(wif_to_pk scripthash_by_address address_by_pubkey wallet_import_format address_by_hash);
use QBitcoin::MyAddress;
use QBitcoin::Generate;
use QBitcoin::Protocol;
use QBitcoin::ConnectionList;
use QBitcoin::MinFee;
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
> qecurrency-cli ping
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "ping", "params": []}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
  "bestblocktime" : n,                    (numeric) time for the current best block
  "initialblockdownload" : true|false,    (boolean) (debug information) estimate of whether this node is in Initial Block Download mode
  "total_coins" : n,                      (numeric) total number of generated (upgraded) coins
  "btc_headers" : n,                      (numeric) number of processed btc block headers
  "btc_scanned" : n,                      (numeric) number of scanned btc blocks
  "btc_synced" : true|false,              (bookean) is btc blockchain fully synced or is in initial block download mode
}

Examples:
> qecurrency-cli getblockchaininfo
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockchaininfo", "params": []}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getblockchaininfo {
    my $self = shift;
    my $best_block;
    if (defined(my $height = QBitcoin::Block->blockchain_height)) {
        $best_block = QBitcoin::Block->best_block($height);
    }
    my $response = {
        chain                => $config->{regtest} ? "regtest" : $config->{testnet} ? "testnet" : "main",
        blocks               => $best_block ? $best_block->height+0   : -1,
        bestblockhash        => $best_block ? unpack("H*", $best_block->hash) : undef,
        weight               => $best_block ? $best_block->weight+0   : -1,
        bestblocktime        => $best_block ? $best_block->time       : -1,
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
        $coinbase //= 0;
        $coinbase += GENESIS_REWARD if defined($best_block);
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
> qecurrency-cli getbestblockhash
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getbestblockhash", "params": []}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
> qecurrency-cli getblockheader "00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockheader", "params": ["00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
        time              => $block->time,
        confirmations     => $best_height - $block->height,
        nTx               => @{$block->tx_hashes}+0,
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
> qecurrency-cli getblockcount
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockcount", "params": []}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
> qecurrency-cli getblock "00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblock", "params": ["00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
        time              => $block->time,
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
> qecurrency-cli getblockhash 1000
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockhash", "params": [1000]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
      "value" : n,                   (numeric) The value in ECR
      "n" : n,                       (numeric) index
      "scriptPubKey" : {             (json object)
        "hex" : "str",               (string) the hex
        "reqSigs" : n,               (numeric) The required sigs
        "type" : "str",              (string) The type, eg 'pubkeyhash'
        "addresses" : [              (json array)
          "str",                     (string) ecurrency address
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
> qecurrency-cli getrawtransaction "mytxid"
> qecurrency-cli getrawtransaction "mytxid" true
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getrawtransaction", "params": ["mytxid", true]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
        my $block = QBitcoin::Block->best_block($tx->block_height) // QBitcoin::Block->find(height => $tx->block_height);
        if ($block) {
            my $best_block = QBitcoin::Block->best_block($best_height);
            $res->{confirm_weight} = $best_block->weight - $block->weight;
            $res->{blockhash} = unpack("H*", $block->hash);
            $res->{blocktime} = $block->time;
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
         "address": amount,    (numeric or string, required) A key-value pair. The key (string) is the ecurrency address, the value (float or string) is the amount in ECR
       },
       ...
     ]

Result:
"hex"    (string) hex string of the transaction

Examples:
> qecurrency-cli createrawtransaction '[{"txid":"myid","vout":0}]' '[{"address":0.01}]'
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "createrawtransaction", "params": ['[{"txid":"myid","vout":0}]', '[{"address":0.01}]"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_createrawtransaction {
    my $self = shift;
    my $inputs  = $self->args->[0];
    my $outputs = $self->args->[1];
    my @in  = map {{ txo => QBitcoin::TXO->new_txo(tx_in => pack("H*", $_->{txid}), num => $_->{vout}+0) }} @$inputs;
    my @out;
    foreach my $out (@$outputs) {
        push @out, map { QBitcoin::TXO->new_txo(value => int($out->{$_} * DENOMINATOR + 0.5), scripthash => scripthash_by_address($_)) } keys %$out;
    }
    my $tx = QBitcoin::Transaction->new(
        in      => \@in,
        out     => \@out,
        tx_type => TX_TYPE_STANDARD,
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
> qecurrency-cli createrawtransaction '[{"txid" : "mytxid","vout":0}]" "{"myaddress":0.01}'
Sign the transaction, and get back the hex
> qecurrency-cli signrawtransactionwithkey "myhex" '["myprivatekey"]'

Send the transaction (signed hex)
> qecurrency-cli sendrawtransaction "signedhex"

As a JSON-RPC call
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "sendrawtransaction", "params": ["signedhex"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
> qecurrency-cli signrawtransactionwithkey "myhex" '["key1","key2"]'
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "signrawtransactionwithkey", "params": ["myhex", ["key1","key2"]]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_signrawtransactionwithkey {
    my $self = shift;
    my $data = Bitcoin::Serialized->new(pack("H*", $self->args->[0]));
    my $privkeys = $self->args->[1];
    my $tx = QBitcoin::Transaction->deserialize($data);
    if (!$tx || $data->length) {
        return $self->response_error("", ERR_DESERIALIZATION_ERROR, "TX decode failed.");
    }
    if (!$tx->is_standard) {
        return $self->response_error("", ERR_INVALID_REQUEST, "Non-standard transaction.");
    }
    $tx->received_from = $self;
    if (!$tx->load_inputs(1)) {
        return $self->response_error("", ERR_DESERIALIZATION_ERROR, "Incorrect transaction data.");
    }
    if ($tx->is_pending) {
        return $self->response_error("", ERR_DESERIALIZATION_ERROR, "Some inputs unknown.");
    }
    my @address = map { QBitcoin::MyAddress->new(private_key => $_) } @$privkeys;
    my @errors;
    my $input_amount = 0;
    foreach my $num (0 .. $#{$tx->in}) {
        my $in = $tx->in->[$num];
        my $txo = $in->{txo};
        if ($txo->tx_out) {
            # Already confirmed spent
            return $self->response_error("", ERR_DESERIALIZATION_ERROR, "Input " . $txo->tx_in_str . ":" . $txo->num . " already confirmed spent.");
        }
        $input_amount += $txo->value;
        my ($address, $script);
        foreach my $addr (@address) {
            if ($script = $addr->script_by_hash($txo->scripthash)) {
                $address = $addr;
                last;
            }
        }
        if ($address) {
            $tx->make_sign($in, $address, $num);
        }
        else {
            push @errors, {
                txid       => unpack("H*", $txo->tx_in),
                vout       => $in->{txo}->num,
                scripthash => unpack("H*", $txo->scripthash),
                error      => "Unknown scripthash",
            };
        }
    }
    if (!@errors) {
        $tx->calculate_hash;
        if (QBitcoin::Transaction->check_by_hash($tx->hash)) {
            return $self->response_error("", ERR_VERIFY_ALREADY_IN_CHAIN, "Transaction already published.");
        }
    }

    my $output_amount;
    foreach my $out (@{$tx->out}) {
        $output_amount += $out->{value};
    }
    if ($input_amount < $output_amount) {
        return $self->response_error("", ERR_INVALID_REQUEST, "Insufficient funds: $input_amount < $output_amount");
    }
    my $tx_data = $tx->serialize_unsigned;
    my $fee_per_kb = ($input_amount - $output_amount) * length($tx_data) / 1024;
    my $max_fee_per_kb = $self->max_fee_per_kb;
    if ($max_fee_per_kb && $fee_per_kb > $max_fee_per_kb) {
        return $self->response_error("", ERR_INVALID_REQUEST, "Transaction fee too high: " . $fee_per_kb / DENOMINATOR . " > " . $max_fee_per_kb / DENOMINATOR . " ECR/kb");
    }

    return $self->response_ok({
        hex      => unpack("H*", $tx_data),
        complete => @errors ? FALSE : TRUE,
        errors   => \@errors,
    });
}

sub max_fee_per_kb {
    my $self = shift;
    return $config->{max_fee_per_kb} if defined $config->{max_fee_per_kb};
    return 0 if $config->{testnet} || $config->{regtest};
    return 10000000; # 0.1 ECR
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
> qecurrency-cli decoderawtransaction "hexstring"
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "decoderawtransaction", "params": ["hexstring"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
> qecurrency-cli getmempoolinfo
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getmempoolinfo", "params": []}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getmempoolinfo {
    my $self = shift;

    my @mempool = QBitcoin::Transaction->mempool_list();
    return $self->response_ok({
        loaded => mempool_synced() ? TRUE : FALSE,
        size   => @mempool+0,
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
> qecurrency-cli getrawmempool true
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getrawmempool", "params": [true]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getrawmempool {
    my $self = shift;
    my $verbose = $self->args->[0] // FALSE;

    return $self->response_ok([ map { $verbose ? $_->as_hashref : unpack("H*", $_->hash) } QBitcoin::Transaction->mempool_list() ]);
}

$PARAMS{validateaddress} = "address";
$HELP{validateaddress} = qq(
validateaddress "address"

Return information about the given ecurrency address.

Arguments:
1. address    (string, required) The address to validate

Result:
{                               (json object)
  "isvalid" : true|false,       (boolean) If the address is valid or not. If not, this is the only property returned.
  "address" : "str",            (string) The ecurrency address validated
  "scriptHash" : "hex",         (string) The hex-encoded scriptHash generated by the address
}

Examples:
> qecurrency-cli validateaddress "myaddress"
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "validateaddress", "params": ["myaddress"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
> qecurrency-cli getnetworkinfo
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getnetworkinfo", "params": []}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getnetworkinfo {
    my $self = shift;
    my $connect_in = 0;
    my $connect_out = 0;
    foreach my $connection (QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN)) {
        $connection->direction == DIR_IN ? $connect_in++ : $connect_out++;
    }
    return $self->response_ok({
        version         => VERSION,
        subversion      => "/QEcurrency:0.1/",
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
> qecurrency-cli getindexinfo
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getindexinfo", "params": []}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
> qecurrency-cli getchaintxstats
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getchaintxstats", "params": [2016]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
        time                      => $last_block->time,
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
> qecurrency-cli getblockstats '"00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"'
> qecurrency-cli getblockstats 1000
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockstats", "params": ["00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getblockstats", "params": [1000]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
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
        time       => $block->time,
        total_out  => sum0(map { $_->value } map { @{$_->out} } @{$block->transactions})/DENOMINATOR,
        total_size => sum0(map { $_->size } @{$block->transactions}),
        txs        => @{$block->transactions}+0,
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
  "fee" : n,                            (numeric) transaction fee in ECR (DEPRECATED)
  "time" : xxx,                         (numeric) local time transaction entered pool in seconds since 1 Jan 1970 GMT
}

Examples:
> qecurrency-cli getmempoolentry "mytxid"
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getmempoolentry", "params": ["mytxid"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getmempoolentry {
    my $self = shift;
    my $hash = pack("H*", $self->args->[0]);
    my $verbose = $self->args->[1] // TRUE;
    my $tx = QBitcoin::Transaction->get($hash)
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "No such mempool");
    return $self->response_ok($tx->as_hashref);
}

$PARAMS{importprivkey} = "privkey";
$HELP{importprivkey} = qq(
importprivkey "privkey"

Adds a private key (as returned by dumpprivkey) to your wallet.

Arguments:
1. privkey    (string, required) The private key (see dumpprivkey)

Result:
null    (json null)

Examples:

Dump a private key
> qecurrency-cli dumpprivkey "myaddress"

Import the private key
> qecurrency-cli importprivkey "mykey"

As a JSON-RPC call
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "importprivkey", "params": ["mykey"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_importprivkey {
    my $self = shift;
    my $private_key = wif_to_pk($self->args->[0]);
    my ($pk_alg) = pk_alg($private_key)
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Incorrect private key");
    my $privkey = pk_import($private_key, $pk_alg)
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Incorrect private key");
    my $pubkey = $privkey->pubkey_by_privkey
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "This type of private key is not supported for my_address");
    my $address = address_by_pubkey($pubkey, $pk_alg);
    my $my_address = QBitcoin::MyAddress->create({
        private_key => wallet_import_format($private_key),
        address     => $address,
    });
    QBitcoin::Generate->load_address_utxo($my_address);

    return $self->response_ok("Private key for address $address imported");
}

$PARAMS{dumpprivkey} = "address";
$HELP{dumpprivkey} = qq(
dumpprivkey "address"

Reveals the private key corresponding to 'address'.
Then the importprivkey can be used with this output

Arguments:
1. address    (string, required) The address for the private key

Result:
"str"    (string) The private key

Examples:
> qecurrency-cli dumpprivkey "myaddress"
> qecurrency-cli importprivkey "mykey"
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "dumpprivkey", "params": ["myaddress"]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_dumpprivkey {
    my $self = shift;
    $config->{allow_dumpprivkey}
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "This command is disabled");
    my $scripthash = scripthash_by_address($self->args->[0])
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "The address is not correct");
    my $my_address = QBitcoin::MyAddress->get_by_hash($scripthash)
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "Private key is unknown for this address");
    return $self->response_ok($my_address->private_key);
}

$PARAMS{getpeerinfo} = "";
$HELP{getpeerinfo} = qq(
Returns data about each connected network node as a json array of objects.

Result:
[                                     (json array)
  {                                   (json object)
    "addr" : "str",                   (string) (host:port) The IP address and port of the peer
    "addrlocal" : "str",              (string) (ip:port) Bind address of the connection to the peer
    "network" : "str",                (string) Network (ipv4, ipv6, onion, i2p, not_publicly_routable)
    "createtime" : n,                 (numeric) The connection create time in seconds since epoch
    "bytessent" : n,                  (numeric) The total bytes sent
    "bytesrecv" : n,                  (numeric) The total bytes received
    "objsent" : n,                    (numeric) The total objects sent
    "objrecv" : n,                    (numeric) The total objects received
    "pingtime" : n,                   (numeric) ping time (if available)
    "minping" : n,                    (numeric) minimum observed ping time (if any at all)
    "inbound" : true|false,           (boolean) Inbound (true) or Outbound (false)
    "protocol" : "str",               (string) Protocol (qecurrency, ecurrency)
  },
]

Examples:
> qecurrency-cli getpeerinfo
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getpeerinfo", "params": []}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getpeerinfo {
    my $self = shift;
    my @peers;
    foreach my $connection (QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN, PROTOCOL_BITCOIN)) {
        my $peer = $connection->peer;
        push @peers, {
            addr        => $connection->ip . ":" . $connection->port,
            addrlocal   => $connection->my_ip . ":" . $connection->my_port,
            inbound     => $connection->direction == DIR_IN ? TRUE : FALSE,
            protocol    => $connection->type,
            network     => "ipv4",
            createtime  => $peer->create_time,
            bytessent   => $peer->bytes_sent,
            bytesrecv   => $peer->bytes_recv,
            objsent     => $peer->obj_sent,
            objrecv     => $peer->obj_recv,
            reputation  => $peer->reputation,
            # minping     => $peer->ping_min_ms / 1000,
            # pingtime    => $peer->ping_avg_ms / 1000,
        };
    }
    return $self->response_ok(\@peers);
}

$PARAMS{getaddressbalance} = "address minconf?";
$HELP{getaddressbalance} = qq{
getaddressbalance "address" ( minconf )

Returns the total amount on the given address in transactions with at least minconf confirmations.

Arguments:
1. address    (string, required) The ecurrency address for transactions.
2. minconf    (numeric, optional, default=1, max=${\(INCORE_LEVELS+1)}) Only include transactions confirmed at least this many times.

Result:
n    (numeric) The total amount in ECR unspent at this address.

Examples:

The amount from transactions with at least 1 confirmation
> qecurrency-cli getaddressbalance "myaddress"

The amount including unconfirmed transactions, zero confirmations
> qecurrency-cli getaddressbalance "myaddress" 0

The amount with at least 6 confirmations
> qecurrency-cli getaddressbalance "myaddress" 6

As a JSON-RPC call
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getaddressbalance", "params": ["myaddress", 6]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
};
sub cmd_getaddressbalance {
    my $self = shift;
    my $scripthash = scripthash_by_address($self->args->[0])
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "The address is not correct");
    blockchain_synced() && mempool_synced()
        or return $self->response_error("", ERR_INTERNAL_ERROR, "Blockchain is not synced");
    my $minconf = $self->args->[1] // 1;
    my $value = 0;
    my $best_height;
    if ($minconf > 1) {
        $best_height = QBitcoin::Block->blockchain_height
            or return $self->response_ok("0");
    }
    foreach my $utxo (QBitcoin::TXO->get_scripthash_utxo($scripthash)) {
        if (my $tx = QBitcoin::Transaction->get($utxo->tx_in)) {
            if (!defined $tx->block_height) {
                next if $minconf;
            }
            elsif ($minconf > 1) {
                next if $tx->block_height > $best_height - $minconf + 1;
            }
        }
        else {
            next if QBitcoin::Transaction->has_pending($utxo->tx_in);
        }
        $value += $utxo->value;
    }
    if (my ($script) = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        foreach my $utxo (grep { !$_->is_cached } QBitcoin::TXO->find(scripthash => $script->id, tx_out => undef)) {
            $value += $utxo->value;
        }
    }
    return $self->response_ok($value/DENOMINATOR);
}

$PARAMS{getreceivedbyaddress} = "address minconf?";
$HELP{getreceivedbyaddress} = qq{
getreceivedbyaddress "address" ( minconf )

Returns the total received amount on the given address in transactions with at least minconf confirmations.

Arguments:
1. address    (string, required) The ecurrency address for transactions.
2. minconf    (numeric, optional, default=1, max=${\(INCORE_LEVELS+1)}) Only include transactions confirmed at least this many times.

Result:
n    (numeric) The total amount in ECR received at this address.

Examples:

The amount from transactions with at least 1 confirmation
> qecurrency-cli getaddressbalance "myaddress"

The amount including unconfirmed transactions, zero confirmations
> qecurrency-cli getreceivedbyaddress "myaddress" 0

The amount with at least 6 confirmations
> qecurrency-cli getreceivedbyaddress "myaddress" 6

As a JSON-RPC call
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getreceivedbyaddress", "params": ["myaddress", 6]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
};
sub cmd_getreceivedbyaddress {
    my $self = shift;
    my $scripthash = scripthash_by_address($self->args->[0])
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "The address is not correct");
    blockchain_synced() && mempool_synced()
        or return $self->response_error("", ERR_INTERNAL_ERROR, "Blockchain is not synced");
    my $minconf = $self->args->[1] // 1;
    my $value = 0;
    my $best_height;
    if ($minconf > 1) {
        $best_height = QBitcoin::Block->blockchain_height
            or return $self->response_ok("0");
    }
    foreach my $txo (QBitcoin::TXO->get_scripthash_txo($scripthash)) {
        if (my $tx = QBitcoin::Transaction->get($txo->tx_in)) {
            if (!defined $tx->block_height) {
                next if $minconf;
            }
            elsif ($minconf > 1) {
                next if $tx->block_height > $best_height - $minconf + 1;
            }
        }
        else {
            next if QBitcoin::Transaction->has_pending($txo->tx_in);
        }
        $value += $txo->value;
    }
    if (my ($script) = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        foreach my $utxo (grep { !$_->is_cached } QBitcoin::TXO->find(scripthash => $script->id)) {
            $value += $utxo->value;
        }
    }
    return $self->response_ok($value/DENOMINATOR);
}

$PARAMS{listunspent} = "address minconf?";
$HELP{listunspent} = qq{
listunspent address ( minconf )

Returns array of unspent transaction outputs on the given address with at least minconf confirmations.

Arguments:
1. address    (string, required) The ecurrency address for transactions.
2. minconf    (numeric, optional, default=1, max=${\(INCORE_LEVELS+1)}) Only include transactions confirmed at least this many times.

Result:
[                                (json array)
  {                              (json object)
    "txid" : "hex",              (string) the transaction id
    "vout" : n,                  (numeric) the vout value
    "address" : "str",           (string) the ecurrency address
    "amount" : n,                (numeric) the transaction output amount in ECR
    "confirmations" : n,         (numeric) The number of confirmations
  },
  ...
]

Examples:
> qecurrency-cli listunspent "myaddress"
> qecurrency-cli listunspent "myaddress" 6
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "listunspent", "params": ["myaddress",6]}' -H 'content-type: application/json;' http://127.0.0.1:${\RPC_PORT}/
};
sub cmd_listunspent {
    my $self = shift;
    my $scripthash = scripthash_by_address($self->args->[0])
        or return $self->response_error("", ERR_INVALID_ADDRESS_OR_KEY, "The address is not correct");
    blockchain_synced() && mempool_synced()
        or return $self->response_error("", ERR_INTERNAL_ERROR, "Blockchain is not synced");
    my $minconf = $self->args->[1] // 1;
    my $best_height;
    if ($minconf > 1) {
        $best_height = QBitcoin::Block->blockchain_height
            or return $self->response_ok([]);
    }
    my @utxo;
    foreach my $utxo (QBitcoin::TXO->get_scripthash_utxo($scripthash)) {
        if (my $tx = QBitcoin::Transaction->get($utxo->tx_in)) {
            if (!defined $tx->block_height) {
                next if $minconf;
            }
            elsif ($minconf > 1) {
                next if $tx->block_height > $best_height - $minconf + 1;
            }
        }
        else {
            next if QBitcoin::Transaction->has_pending($utxo->tx_in);
        }
        push @utxo, $utxo;
    }
    if (my ($script) = QBitcoin::RedeemScript->find(hash => $scripthash)) {
        push @utxo, grep { !$_->is_cached } QBitcoin::TXO->find(scripthash => $script->id, tx_out => undef);
    }
    return $self->response_ok([ map +{
        txid    => unpack("H*", $_->tx_in),
        vout    => $_->num + 0,
        address => address_by_hash($_->scripthash),
        amount  => $_->value / DENOMINATOR,
        # confirmations => ...
    }, @utxo ]);
}

$PARAMS{listmyaddresses} = "";
$HELP{listmyaddresses} = qq(
Returns the list of addresses in the wallet.

Result:
{                         (json object) json object with addresses as keys
  "address" : {           (json object) json object with information about address
    "algo" : [ "str" ]    (json array) list of crypto algorithms supported by the address
  },
  ...
}

Examples:
> qecurrency-cli listmyaddresses
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "listmyaddresses", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_listmyaddresses {
    my $self = shift;
    my %list;
    foreach my $my_address (QBitcoin::MyAddress->my_address) {
        $list{$my_address->address} = {
            algo => [ map { CRYPT_ALGO_NAMES->{$_} } $my_address->algo ],
        };
    }
    $self->response_ok(\%list);
}

$PARAMS{getbalance} = "minconf?";
$HELP{getbalance} = qq(
getbalance ( minconf )

Returns total balance of the addresses in the wallet with at least minconf confirmations.

Result:
n    (numeric) The total amount in ECR in the wallet.

Examples:
> qecurrency-cli getbalance
> qecurrency-cli getbalance 6
> curl --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getbalance", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getbalance {
    my $self = shift;
    blockchain_synced() && mempool_synced()
        or return $self->response_error("", ERR_INTERNAL_ERROR, "Blockchain is not synced");
    my @my_txo = QBitcoin::TXO->my_utxo();
    my $minconf = $self->args->[0] // 1;
    my $value = 0;
    if ($minconf) {
        my $best_height = QBitcoin::Block->blockchain_height
            or return $self->response_ok("0");
        foreach my $txo (@my_txo) {
            my $block_height = QBitcoin::Transaction->check_by_hash($txo->tx_in)
                or next;
            next if $block_height < 0;
            next if $block_height > $best_height - $minconf + 1;
            $value += $txo->value;
        }
    }
    else {
        $value = sum0(map { $_->value } @my_txo);
    }
    return $self->response_ok($value/DENOMINATOR);
}

$PARAMS{getnewaddress} = "address_type?";
$HELP{getnewaddress} = qq(
getnewaddress ( address_type )

Returns a new ecurrency address and private key.
Private key is not stored in the wallet and can be imported using importprivkey.

Arguments:
1. address_type    (string, optional, default="ecdsa") The address type to use. Options are "ecdsa", "falcon".

Result:
{
    "address",     (string) The new ecurrency address
    "private_key", (string) The private key for the new address
}

Examples:
> qecurrency-cli getnewaddress
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "getnewaddress", "params": []}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_getnewaddress {
    my $self = shift;
    my $algo = $self->args->[0] // CRYPT_ALGO_ECDSA;
    my $keypair = generate_keypair($algo);
    my $address = address_by_pubkey($keypair->pubkey_by_privkey, $algo);
    return $self->response_ok({ address => $address, private_key => wallet_import_format($keypair->pk_serialize) });
}

$PARAMS{estimatesmartfee} = "conf_target estimate_mode?";
$HELP{estimatesmartfee} = qq(
estimatesmartfee conf_target ( "estimate_mode" )

Estimates the approximate fee per kilobyte needed for a transaction to begin
confirmation within conf_target blocks if possible.

Arguments:
1. conf_target      (numeric, required) Confirmation target in blocks (1 - 99)
2. estimate_mode    (string, optional, default=CONSERVATIVE) The fee estimate mode.
                    Whether to return a more conservative estimate which also satisfies
                    a longer history. A conservative estimate potentially returns a
                    higher feerate and is more likely to be sufficient for the desired
                    target, but is not as responsive to short term drops in the
                    prevailing fee market.  Must be one of:
                    "ECONOMICAL"
                    "CONSERVATIVE"

Result:
{                   (json object)
  "feerate" : n,    (numeric, optional) estimate fee rate in ECR/kB (only present if no errors were encountered)
  "errors" : [      (json array, optional) Errors encountered during processing (if there are any)
    "str",          (string) error
    ...
  ],
}

Examples:
> qecurrency-cli estimatesmartfee 6
> curl --user myusername --data-binary '{"jsonrpc": "1.0", "id": "curltest", "method": "estimatesmartfee", "params": [6]}' -H 'content-type: text/plain;' http://127.0.0.1:${\RPC_PORT}/
);
sub cmd_estimatesmartfee {
    my $self = shift;
    my ($target, $mode) = @{$self->args};
    $mode //= "CONSERVATIVE";
    $target /= 2 if uc($mode) eq "CONSERVATIVE";
    blockchain_synced() && mempool_synced()
        or return $self->response_error("", ERR_INTERNAL_ERROR, "Blockchain is not synced");
    my $height;
    if (!defined(my $height = QBitcoin::Block->blockchain_height)) {
        return $self->response_error("", ERR_INTERNAL_ERROR, "Blockchain is not initialized");
    }
    my $best_block = QBitcoin::Block->best_block($height)
        or return $self->response_error("", ERR_INTERNAL_ERROR, "Best block not found");
    my @mempool = QBitcoin::Transaction->mempool_list();
    if (@mempool < $target) {
        return $self->response_ok({ feerate => 0 });
    }
    if ($best_block->min_fee <= QBitcoin::MinFee->MIN_FEE) {
        return $self->response_ok({ feerate => QBitcoin::MinFee->MIN_FEE });
    }
    my $size = sum0 map { $_->size } grep { $_->is_standard && $_->fee * 1024 / $_->size > $best_block->min_fee } @mempool;
    if ($size < $target * $best_block->size) {
        return $self->response_ok({ feerate => $best_block->min_fee });
    }
    $size = 0;
    my $prev_tx;
    foreach my $tx (sort { $b->fee / $b->size <=> $a->fee / $a->size } @mempool) {
        if ($size += $tx->size > $best_block->size) {
            return $self->response_ok({ feerate => $prev_tx ? $prev_tx->fee * 1024 / $prev_tx->size : $tx->fee * 1024 / $tx->size });
        }
        $prev_tx = $tx;
    }
    return $self->response_ok({ feerate => $prev_tx->fee * 1024 / $prev_tx->size });
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
# listbanned
# setban

# signmessagewithprivkey
# verifymessage
# getaddressinfo

# listreceivedbyaddress
# listtransactions

1;
