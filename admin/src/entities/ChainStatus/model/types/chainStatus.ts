import type { BaseUnits } from '@/shared/lib/baseUnits';

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
    weight: BaseUnits;
    mempool_size: number;
    total_coins: BaseUnits;
    blocks: number;
    bestblocktime: number;
    genesistime: number;
    reward: BaseUnits;
    btc_synced: boolean;
    bestblockhash: string;
    chain: string;
    mempool_bytes: number;
    initialblockdownload: boolean;
    wallet?: WalletStatus;
}
