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
}
