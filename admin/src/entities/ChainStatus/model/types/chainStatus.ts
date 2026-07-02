export interface WalletStatus {
    password_set: boolean;
    keys_encrypted: boolean;
    locked: boolean;
    generate: boolean;
    staking_active: boolean;
}

export interface ChainStatus {
    btc_scanned: number;
    btc_headers: number;
    weight: number;
    mempool_size: number;
    total_coins: number;
    blocks: number;
    bestblocktime: number;
    genesistime: number;
    reward: number;
    btc_synced: boolean;
    bestblockhash: string;
    chain: string;
    mempool_bytes: number;
    initialblockdownload: boolean;
    wallet?: WalletStatus;
}
