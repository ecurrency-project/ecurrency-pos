package QBitcoin::Const;
use warnings;
use strict;

use constant VERSION            => "0.1";

use constant QBITCOIN_CONST => {
    VERSION                 => VERSION,
    SOFTWARE                => "/QECurrencyCore:" . VERSION . "/",
    DB_VERSION              => 3,
    BLOCK_INTERVAL          => 10, # sec
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
    SYNC_PEER_TIMEOUT       => 8,  # sec, switch sync peer if no bytes received
    BIND_ADDR               => '*',
    RPC_ADDR                => '127.0.0.1',
    LISTEN_QUEUE            => 5,
    PEER_RECONNECT_TIME     => 10,
    TXO_DATA_TAG            => "T",
    REWARD_DIVIDER          => 500, # reward for block is 1/500 of the reward fund
    MAX_BLOCK_SIZE          => 8*1024*1024,
    MAX_TX_IN_BLOCK         => 65535,
    MAX_TX_SIZE             => 2*1024*1024,
    MAX_INPUTS_PER_TX       => 65535,
    MAX_OUTPUTS_PER_TX      => 65535,
    MAX_REDEEM_SCRIPT_SIZE  => 65535,
    MAX_SIGLIST_SIZE        => 65535,
    MAX_TXO_DATA_SIZE       => 65535,
    BLOCKS_IN_BATCH         => 200,
    BLOCK_LOCATOR_INTERVAL  => 100, # < BLOCKS_IN_BATCH
    MAX_PENDING_BLOCKS      => 256, # > BLOCKS_IN_BATCH
    MAX_PENDING_TX          => 128,
    MAX_EMPTY_TX_IN_BLOCK   => 1,
    MAX_EMPTY_TX_SIZE       => 32768, # Disable huge transactions with zero fee to prevent spam
    MAX_MEMPOOL_SIZE        => 100*1024*1024, # 100 MB total size of limited tx types in mempool
    MAX_MEMPOOL_ZERO_FEE_TX => 1024,          # max zero-fee txs in mempool
    COINBASE_CONFIRM_TIME   => 900,     # 15 minutes
    COINBASE_CONFIRM_BLOCKS => 6,
    COINBASE_WEIGHT_TIME    => 365*24*3600, # 1 year
    # Slashing: penalty for a validator that signs two conflicting blocks (same
    # stake UTXO, same timeslot). The fine is a consensus value (must be identical
    # on every node so the trustless slashing tx is byte-deterministic), NOT a
    # per-node config. fine = floor(value * NUM/DEN) per slashed scripthash, taken
    # as tx fee into the reward_fund; the rest is refunded to the slashed owner.
    SLASHING_FINE_NUM       => 1,
    SLASHING_FINE_DEN       => 10,  # 10%
    # How long (in best-chain blocks) a seen stake is retained in memory to detect
    # equivocation. Beyond INCORE_LEVELS + FORCE_BLOCKS a reorg is penalized, so an
    # equivocation buried deeper can no longer be profitably slashed anyway.
    SLASHING_WINDOW         => 6 + 100, # INCORE_LEVELS + FORCE_BLOCKS
    CONFIG_DIR              => "/etc",
    CONFIG_NAME             => "qecurrency.conf",
    ZERO_HASH               => "\x00" x 32,
    IPV6_V4_PREFIX          => "\x00" x 10 . "\xff" x 2,
    MIN_CONNECTIONS         => 5,
    MIN_OUT_CONNECTIONS     => 2,
    MAX_IN_CONNECTIONS      => 8,
    MAX_IN_CONNECTIONS_PER_IP => 4, # several nodes may share one IP (NAT); duplicates are detected by version nonce
    MAX_RPC_CONNECTIONS     => 10,
    MAX_REST_CONNECTIONS    => 10,
    MAX_ADDR_PEERS          => 50,
    ANNOUNCE_MAX_FAILS      => 3, # do not announce peers with this many failed connects since last success
    PEER_PROBE_PERIOD       => 15, # sec, min interval between starting reachability probes of idle peers
    MAX_PROBE_CONNECTIONS   => 2,  # max simultaneous reachability-probe connections
    PEER_REVERIFY_PERIOD    => 6*3600, # sec, re-probe an already verified peer not contacted for this long
    PEER_PROBE_DEAD_FAILS   => 10, # with this many consecutive failed connects the peer is considered long-dead
    PEER_PROBE_DEAD_PERIOD  => 24*3600, # sec, probe a long-dead peer at most once per this period
    PEER_CLEANUP_PERIOD     => 3600, # sec, how often to scan the peer table for expired records
    PEER_EXPIRE_PERIOD      => 30*24*3600, # sec, forget a non-pinned peer with no activity for this long (if also unreachable)
    PEER_EXPIRE_MIN_FAILS   => 3, # do not expire a peer until this many connects failed since its last activity
    MAX_INT64               => unpack("Q>", pack("H*", "7fffffffffffffff")), # 2^63-1, prevent warning about non-portable
    MAX_UINT64              => unpack("Q>", pack("H*", "ffffffffffffffff")), # 2^64-1, prevent warning about non-portable
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
    TX_TYPE_TOKENS   => 4,
    TX_TYPE_SLASHING => 5,
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

use constant TOKEN_TXO_TYPES => {
    TOKEN_TXO_TYPE_TRANSFER    => "\x01",
    TOKEN_TXO_TYPE_PERMISSIONS => "\x02",
    TOKEN_TXO_TYPE_DECIMALS    => "\x03",
    TOKEN_TXO_TYPE_SYMBOL      => "\x04",
    TOKEN_TXO_TYPE_NAME        => "\x05",
};

use constant TOKEN_PERMISSION_BITS => {
    TOKEN_PERMISSION_MINT => 1,
};

use constant TOKEN_DEFAULT_DECIMALS => 6;

# use constant TX_TYPES_NAMES  => [ "unknown", "standard", "stake", "coinbase", "tokens" ];
use constant TX_NAME_BY_TYPE => { reverse %{&TX_TYPES_CONST} };
use constant TX_TYPES_NAMES  =>
    [ map { s/^tx_type_//r } map { lc(TX_NAME_BY_TYPE->{$_} // "unknown") } 0 .. (sort { $b <=> $a } values %{&TX_TYPES_CONST})[0] ];

use constant QBITCOIN_CONST;
use constant STATE_CONST;
use constant DIR_CONST;
use constant PROTOCOL_CONST;
use constant PEER_STATUS_CONST;
use constant TX_TYPES_CONST;
use constant CRYPT_ALGO;
use constant SIGHASH_TYPES;
use constant TOKEN_TXO_TYPES;
use constant TOKEN_PERMISSION_BITS;

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
    keys %{&TOKEN_TXO_TYPES},
    keys %{&TOKEN_PERMISSION_BITS},
    'TX_TYPES_NAMES',
    'PROTOCOL2NAME',
    'CRYPT_ALGO_NAMES',
    'CRYPT_ALGO_BY_NAME',
    'CRYPT_ALGO_POSTQUANTUM',
    'TOKEN_DEFAULT_DECIMALS',
);
push @EXPORT, qw(timeslot);

1;
