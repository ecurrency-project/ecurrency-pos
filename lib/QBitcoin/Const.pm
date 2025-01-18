package QBitcoin::Const;
use warnings;
use strict;

use QBitcoin::Script::OpCodes qw(:OPCODES);

use constant GENESIS_BLOCK_HASH => "219a2e1a17d6aaab10d2d16db3a7fe32b0292ed516315cf541526722793888af";
use constant GENESIS_BLOCK_HASH_TESTNET => "bee62fcd5231d448c17972ef59a08b66f1f7fc047422635ac59491df21eb2350";
use constant QBT_BURN_HASH      => pack("H*", "d800a80216f6e59ec294bffcb5887bc4a5dd0fc9"); # Ecr2Ecr2Ecr2Ecr2Ecr2Ecr2Ecr29CQmx3
use constant QBT_BURN_SCRIPT    => OP_DUP . OP_HASH160 . pack("C", length(QBT_BURN_HASH)) . QBT_BURN_HASH . OP_EQUALVERIFY . OP_CHECKSIG;

use constant QBITCOIN_CONST => {
    VERSION                 => "0.1",
    DB_VERSION              => 2,
    ADDRESS_VER             => "\x80",
    ADDR_MAGIC              => "\x07\x6e",
    PRIVATE_KEY_RE          => qr/^[5KL][1-9A-HJ-NP-Za-km-z]{50,51}$/,
    ADDRESS_RE              => qr/^(?:EC[1-9A-HJ-NP-Za-km-z]{33}|26[k-n][1-9A-HJ-NP-Za-km-z]{49})$/,
    ADDRESS_VER_TESTNET     => "\xEF",
    ADDR_MAGIC_TESTNET      => "\x07\xd1",
    PRIVATE_KEY_TESTNET_RE  => qr/^[9c][1-9A-HJ-NP-Za-km-z]{50,51}$/,
    ADDRESS_TESTNET_RE      => qr/^(?:Et[1-9A-HJ-NP-Za-km-z]{33}|2A[678][1-9A-HJ-NP-Za-km-z]{49})$/,
    BLOCK_INTERVAL          => 10, # sec
    GENESIS_TIME            => 1740384000, # must be divided by BLOCK_INTERVAL*FORCE_BLOCKS
    GENESIS_TIME_TESTNET    => 1737234000,
    FORCE_BLOCKS            => 100, # generate each 100th block even if empty
    INCORE_LEVELS           => 6,
    INCORE_TIME             => 60,
    MAX_VALUE               => 333333333 * 100000000, # ~333M
    DENOMINATOR             => 100000000,
    MAX_COMMAND_LENGTH      => 256,
    READ_BUFFER_SIZE        => 16*1024*1024, # Must be more than MAX_BLOCK_SIZE
    WRITE_BUFFER_SIZE       => 16*1024*1024, # Must be more than MAX_BLOCK_SIZE
    SERVICE_NAME            => "qecurrency",
    SELECT_TIMEOUT          => 10, # sec
    RPC_TIMEOUT             => 4,  # sec
    REST_TIMEOUT            => 4,  # sec
    PEER_PING_PERIOD        => 60, # sec, ping period
    PEER_RECV_TIMEOUT       => 60, # sec, timeout for waiting for pong
    PORT                    => 9666,
    PORT_TESTNET            => 19666,
    BIND_ADDR               => '*',
    RPC_PORT                => 9667, # JSON RPC API
    RPC_PORT_TESTNET        => 19667,
    RPC_ADDR                => '127.0.0.1',
    REST_PORT               => 9668, # Esplora REST API, https://github.com/blockstream/esplora/blob/master/API.md
    REST_PORT_TESTNET       => 19668,
    LISTEN_QUEUE            => 5,
    PEER_RECONNECT_TIME     => 10,
    ECR_PORT                => 9777,
    ECR_PORT_TESTNET        => 19777,
    SEED_PEER               => "seed.ecurrency.org",
    SEED_PEER_TESTNET       => "seed-testnet.ecurrency.org",
    GENESIS_HASH            => pack('H*', GENESIS_BLOCK_HASH),
    GENESIS_HASH_TESTNET    => pack('H*', GENESIS_BLOCK_HASH_TESTNET),
    GENESIS_REWARD          => 50 * 100000000, # 50 QBTC
    REWARD_DIVIDER          => 500, # reward for block is 1/500 of the reward fund
    MAX_BLOCK_SIZE          => 8*1024*1024,
    MAX_TX_IN_BLOCK         => 65535,
    MAX_TX_SIZE             => 2*1024*1024,
    BLOCKS_IN_BATCH         => 200,
    BLOCK_LOCATOR_INTERVAL  => 100, # < BLOCKS_IN_BATCH
    MAX_PENDING_BLOCKS      => 256, # > BLOCKS_IN_BATCH
    MAX_PENDING_TX          => 128,
    MAX_EMPTY_TX_IN_BLOCK   => 1,
    MAX_EMPTY_TX_SIZE       => 32768, # Disable huge transactions with zero fee to prevent spam
    UPGRADE_POW             => 1,
    UPGRADE_FEE             => 0.01, # 1%
    UPGRADE_MAX_BLOCKS      => 4200000, # March 2026
    COINBASE_CONFIRM_TIME   => 900,     # 15 minutes
    COINBASE_CONFIRM_BLOCKS => 6,
    COINBASE_WEIGHT_TIME    => 365*24*3600, # 1 year
    STAKE_MATURITY          => 12*3600, # 12 hours
    QBT_BURN_SCRIPT         => QBT_BURN_SCRIPT,
    QBT_BURN_SCRIPT_LEN     => length(QBT_BURN_SCRIPT),
    CONFIG_DIR              => "/etc",
    CONFIG_NAME             => "qecurrency.conf",
    ZERO_HASH               => "\x00" x 32,
    IPV6_V4_PREFIX          => "\x00" x 10 . "\xff" x 2,
    MIN_CONNECTIONS         => 5,
    MIN_OUT_CONNECTIONS     => 2,
    MAX_IN_CONNECTIONS      => 8,
    ECR_GENESIS             => scalar reverse(pack("H*", "90d5a026af1ce1f31fca0f0ae12f8ce74c73470b151fb0ecbd1b3a8ad0e0ccb9")),
    ECR_GENESIS_TESTNET     => scalar reverse(pack("H*", "a02c0af2102947df4e31444f3b6d7f12df6e18d356830cb277610f42c4f57e85")),
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

use constant TX_TYPES_CONST => {
    TX_TYPE_STANDARD => 1,
    TX_TYPE_STAKE    => 2,
    TX_TYPE_COINBASE => 3,
};

use constant CRYPT_ALGO => {
    # 1..127 for pre-quantum (ECC), 129..255 for post-quantum (Lattice)
    CRYPT_ALGO_ECDSA   => 1,
    CRYPT_ALGO_SCHNORR => 2,
    CRYPT_ALGO_FALCON  => 129,
};
use constant CRYPT_ALGO_POSTQUANTUM => 0x80; # bit-flag

use constant CRYPT_ALGO_NAMES => {
    map { lc(s/^CRYPT_ALGO_//r) } reverse %{&CRYPT_ALGO}
};

use constant CRYPT_ALGO_BY_NAME => {
    map { lc(s/^CRYPT_ALGO_//r) } %{&CRYPT_ALGO}
};

use constant SIGHASH_TYPES => {
    SIGHASH_ALL          => 1,
    SIGHASH_NONE         => 2,
    SIGHASH_SINGLE       => 3,
    SIGHASH_ANYONECANPAY => 0x80, # bit-flag
};

# use constant TX_TYPES_NAMES  => [ "unknown", "standard", "stake", "coinbase" ];
use constant TX_NAME_BY_TYPE => { reverse %{&TX_TYPES_CONST} };
use constant TX_TYPES_NAMES  =>
    [ map { s/^tx_type_//r } map { lc(TX_NAME_BY_TYPE->{$_} // "unknown") } 0 .. (sort values %{&TX_TYPES_CONST})[-1] ];

use constant QBITCOIN_CONST;
use constant STATE_CONST;
use constant DIR_CONST;
use constant PROTOCOL_CONST;
use constant PEER_STATUS_CONST;
use constant TX_TYPES_CONST;
use constant CRYPT_ALGO;
use constant SIGHASH_TYPES;

use constant PROTOCOL2NAME => {
    map { s/BITCOIN/ECurrency/ir } map { s/PROTOCOL_//r } reverse %{&PROTOCOL_CONST}
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
    keys %{&TX_TYPES_CONST},
    keys %{&CRYPT_ALGO},
    keys %{&SIGHASH_TYPES},
    'TX_TYPES_NAMES',
    'PROTOCOL2NAME',
    'CRYPT_ALGO_NAMES',
    'CRYPT_ALGO_BY_NAME',
    'CRYPT_ALGO_POSTQUANTUM',
);
push @EXPORT, qw(timeslot);

1;
