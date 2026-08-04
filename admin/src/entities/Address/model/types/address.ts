import type { BaseUnits } from '@/shared/lib/baseUnits';

interface ChainStats {
    funded_txo_count: number;
    funded_txo_sum: BaseUnits;
    spent_txo_count: number;
    spent_txo_sum: BaseUnits;
    tx_count: number;
}

interface MempoolStats {
    funded_txo_count: number;
    funded_txo_sum: BaseUnits;
    spent_txo_count: number;
    spent_txo_sum: BaseUnits;
    tx_count: number;
}

export interface IAddress {
    chain_stats: ChainStats;
    mempool_stats: MempoolStats;
    tokens: Record<string, BaseUnits>
}

export interface UTXO {
    block_pos: number;
    value: BaseUnits;
    txid: string;
    vout: number;
    status: 'confirmed' | 'unconfirmed';
    token_id?: string;
    token_amount?: BaseUnits;
    token_permissions?: string[];
}
