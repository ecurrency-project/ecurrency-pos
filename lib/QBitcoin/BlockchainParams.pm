package QBitcoin::BlockchainParams;
use warnings;
use strict;
use feature 'state';

use constant MAINNET => {
    GENESIS_HASH       => pack("H*", "219a2e1a17d6aaab10d2d16db3a7fe32b0292ed516315cf541526722793888af"),
    QBT_BURN_HASH      => pack("H*", "d800a80216f6e59ec294bffcb5887bc4a5dd0fc9"), # Ecr2Ecr2Ecr2Ecr2Ecr2Ecr2Ecr29CQmx3
    ADDRESS_VER        => "\x80",
    ADDR_MAGIC         => "\x07\x6e",
    PRIVATE_KEY_RE     => qr/^(?:[5KL][1-9A-HJ-NP-Za-km-z]{50,51}|2[JK][1-9A-HJ-NP-Za-km-z]{1755})$/,
    ADDRESS_RE         => qr/^(?:EC[1-9A-HJ-NP-Za-km-z]{33}|26[k-n][1-9A-HJ-NP-Za-km-z]{49})$/,
    GENESIS_TIME       => 1740384000, # must be divided by BLOCK_INTERVAL*FORCE_BLOCKS
    PORT               => 9666,
    RPC_PORT           => 9667,
    REST_PORT          => 9668, # Esplora REST API, https://github.com/blockstream/esplora/blob/master/API.md
    ECR_PORT           => 9777,
    SEED_PEER          => "seed.ecurrency.org",
    GENESIS_COINBASE   => 0,
    GENESIS_REWARD     => 50 * 100000000, # 50 QBTC
    ECR_GENESIS        => scalar reverse(pack("H*", "90d5a026af1ce1f31fca0f0ae12f8ce74c73470b151fb0ecbd1b3a8ad0e0ccb9")),
    UPGRADE_FINISHED   => 1,
    SLASHING_START     => 1785542400, # 2026-08-01
    STATIC_REWARD_START => 1785542400, # 2026-08-01
    CHECKPOINTS        => {
        # height => pack('H*', "block_hash_hex"),
        1000000 => pack("H*", "17f97cf4a7bda6c31379e185a314fc6e47d6c4987b0f7bc4816c69420537c668"),
    },
};
use constant TESTNET => {
    GENESIS_HASH       => pack("H*", "bee62fcd5231d448c17972ef59a08b66f1f7fc047422635ac59491df21eb2350"),
    QBT_BURN_HASH      => pack("H*", "d800a80216f6e59ec294bffcb5887bc4a5dd0fc9"), # Ecr2Ecr2Ecr2Ecr2Ecr2Ecr2Ecr29CQmx3
    ADDRESS_VER        => "\xef",
    ADDR_MAGIC         => "\x07\xd1",
    PRIVATE_KEY_RE     => qr/^(?:[9c][1-9A-HJ-NP-Za-km-z]{50,51}|3[ST][1-9A-HJ-NP-Za-km-z]{1755})$/,
    ADDRESS_RE         => qr/^(?:Et[1-9A-HJ-NP-Za-km-z]{33}|2A[456][1-9A-HJ-NP-Za-km-z]{49})$/,
    GENESIS_TIME       => 1737234000,
    PORT               => 19666,
    RPC_PORT           => 19667,
    REST_PORT          => 19668,
    ECR_PORT           => 19777,
    SEED_PEER          => "seed-testnet.ecurrency.org",
    GENESIS_COINBASE   => 0,
    GENESIS_REWARD     => 50 * 100000000, # 50 QBTC
    ECR_GENESIS        => scalar reverse(pack("H*", "a02c0af2102947df4e31444f3b6d7f12df6e18d356830cb277610f42c4f57e85")),
    UPGRADE_FINISHED   => 0,
    SLASHING_START     => 1784073600, # 2026-07-15
    STATIC_REWARD_START => 1784073600, # 2026-07-15
    CHECKPOINTS        => {
        150000 => pack("H*", "be4125eb25b4e527f3b87108245ddd6c18875c15b8b6451502b03d8f5eb54667"),
    },
};
use constant REGTEST => {
    GENESIS_HASH       => pack("H*", ""),
    PORT               => 29666,
    RPC_PORT           => 29667,
    REST_PORT          => 29668,
    SEED_PEER          => "",
    SLASHING_START     => 0,
    UPGRADE_FINISHED   => 0,
    CHECKPOINTS        => {},
};
use constant COMMON_CONST => {
    UPGRADE_POW        => 1,
    UPGRADE_FEE        => 0.01, # 1%
    UPGRADE_MAX_BLOCKS => 4200000, # March 2026
    UPGRADE_MAX_VALUE  => 333_000_000 * 100_000_000, # 333M ECR - stop conversion when upgraded reaches this
    STATIC_REWARD      => 10000000,   # 0.1 ECR per block after hardfork 2026-08-01
    REWARD_HALVING     => 10_000_000, # blocks, halving every ~ 3 years and emit 4M QBTC total as block rewards
    STAKE_MATURITY     => 12*3600,    # 12 hours
};

use QBitcoin::Const;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Config;

sub QBT_BURN_SCRIPT() {
    state $qbt_burn_script = OP_DUP . OP_HASH160 . pack("C", 20) . QBT_BURN_HASH() . OP_EQUALVERIFY . OP_CHECKSIG;
}

sub QBT_BURN_LEN() { state $qbt_burn_len = length(QBT_BURN_SCRIPT) }

BEGIN {
    no strict 'refs';
    foreach my $key (keys %{&MAINNET}) {
        *{$key} = sub () {
            $config->{regtest} ? REGTEST->{$key} // MAINNET->{$key} :
                $config->{testnet} ? TESTNET->{$key} : MAINNET->{$key}
        };
    }
};

use constant COMMON_CONST;

use Exporter 'import';
our @EXPORT = (
    keys %{&MAINNET},
    keys %{&COMMON_CONST},
    'QBT_BURN_SCRIPT',
    'QBT_BURN_LEN',
);

1;
