package QBitcoin::Const;
use warnings;
use strict;

use QBitcoin::Script::OpCodes qw(:OPCODES);

use constant GENESIS_BLOCK_HASH => "1234";
use constant QBT_SCRIPT_START   => OP_RETURN . "QBTC";
use constant QBT_BURN_HASH      => pack("H*", "fe5205472fb87124923f4be64292ef289478b06d"); # 1QBitcoin1QBitcoin1QBitcoin1pSAg3e
use constant BTC_TESTNET        => 1;

use constant QBITCOIN_CONST => {
    VERSION                 => "0.1",
    BLOCK_INTERVAL          => 10, # sec
    GENESIS_TIME            => 1635933000, # must be divided by BLOCK_INTERVAL*FORCE_BLOCKS
    FORCE_BLOCKS            => 100, # generate each 100th block even if empty
    INCORE_LEVELS           => 6,
    INCORE_TIME             => 60,
    MIN_FEE                 => 0.00000001, # 1 satoshi
    MAX_VALUE               => 21000000 * 100000000, # 21M
    DENOMINATOR             => 100000000,
    COMPACT_MEMORY          => 1,
    MAX_COMMAND_LENGTH      => 256,
    READ_BUFFER_SIZE        => 16*1024*1024, # Must be more than MAX_BLOCK_SIZE
    WRITE_BUFFER_SIZE       => 16*1024*1024, # Must be more than MAX_BLOCK_SIZE
    SERVICE_NAME            => "qbitcoin",
    SELECT_TIMEOUT          => 10, # sec
    RPC_TIMEOUT             => 4,  # sec
    REST_TIMEOUT            => 4,  # sec
    PEER_RECV_TIMEOUT       => 60, # sec, ping period and timeout for waiting for pong
    PORT                    => 9555,
    BIND_ADDR               => '*',
    RPC_PORT                => 9556, # JSON RPC API
    RPC_ADDR                => '127.0.0.1',
    REST_PORT               => 9557, # Esplora REST API, https://github.com/blockstream/esplora/blob/master/API.md
    LISTEN_QUEUE            => 5,
    PEER_RECONNECT_TIME     => 10,
    BTC_TESTNET             => BTC_TESTNET,
    BTC_PORT                => BTC_TESTNET ? 18333 : 8333,
    GENESIS_HASH            => pack('H*', GENESIS_BLOCK_HASH),
    GENESIS_HASH_HEX        => GENESIS_BLOCK_HASH,
    MAX_BLOCK_SIZE          => 8*1024*1024,
    MAX_TX_IN_BLOCK         => 65535,
    BLOCK_HEADER_SIZE       => 200, # TODO: calculate precise value
    MAX_TX_SIZE             => 2*1024*1024,
    BLOCKS_IN_BATCH         => 200,
    BLOCK_LOCATOR_INTERVAL  => 100, # < BLOCKS_IN_BATCH
    MAX_PENDING_BLOCKS      => 256, # > BLOCKS_IN_BATCH
    MAX_PENDING_TX          => 128,
    MAX_EMPTY_TX_IN_BLOCK   => 1,
    UPGRADE_POW             => 1,
    UPGRADE_FEE             => 0.01, # 1%
    COINBASE_CONFIRM_TIME   => 2*3600, # 2 hours
    COINBASE_CONFIRM_BLOCKS => 6,
    COINBASE_WEIGHT_TIME    => 365*24*3600, # 1 year
    BTC_TESTNET             => 1,
    QBT_SCRIPT_START        => QBT_SCRIPT_START,
    QBT_SCRIPT_START_LEN    => length(QBT_SCRIPT_START),
    QBT_BURN_SCRIPT         => OP_DUP . OP_HASH160 . pack("C", length(QBT_BURN_HASH)) . QBT_BURN_HASH . OP_EQUALVERIFY . OP_CHECKSIG,
    CONFIG_DIR              => "/etc",
    CONFIG_NAME             => "qbitcoin.conf",
    ZERO_HASH               => "\x00" x 32,
    IPV6_V4_PREFIX          => "\x00" x 10 . "\xff" x 2,
    MIN_CONNECTIONS         => 5,
    MIN_OUT_CONNECTIONS     => 2,
    MAX_IN_CONNECTIONS      => 8,
};

use constant STATE_CONST => {
    STATE_CONNECTED    => 1,
    STATE_CONNECTING   => 2,
    STATE_DISCONNECTED => 3,
};

use constant DIR_CONST => {
    DIR_IN  => 0,
    DIR_OUT => 1,
};

use constant PROTOCOL_CONST => {
    PROTOCOL_QBITCOIN => 1,
    PROTOCOL_BITCOIN  => 2,
    PROTOCOL_RPC      => 3,
    PROTOCOL_REST     => 4,
};

use constant PEER_STATUS_CONST => {
    PEER_STATUS_ACTIVE => 0,
    PEER_STATUS_BANNED => 1, # disabled incoming
    PEER_STATUS_NOCALL => 2, # disabled outgoing
};

use constant QBITCOIN_CONST;
use constant STATE_CONST;
use constant DIR_CONST;
use constant PROTOCOL_CONST;
use constant PEER_STATUS_CONST;

use constant PROTOCOL2NAME => {
    map { s/BITCOIN/Bitcoin/r } map { s/PROTOCOL_//r } reverse %{&PROTOCOL_CONST}
};

sub timeslot($) {
    my $time = int($_[0]);
    $time - $time % BLOCK_INTERVAL;
}

use Exporter qw(import);
our @EXPORT = (
    keys %{&QBITCOIN_CONST},
    keys %{&STATE_CONST},
    keys %{&DIR_CONST},
    keys %{&PROTOCOL_CONST},
    keys %{&PEER_STATUS_CONST},
    'PROTOCOL2NAME',
);
push @EXPORT, qw(timeslot);

1;
