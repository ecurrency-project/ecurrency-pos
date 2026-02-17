interface ChainStats {
    funded_txo_count: number;
    funded_txo_sum: number;
    spent_txo_count: number;
    spent_txo_sum: number;
    tx_count: number;
}

interface MempoolStats {
    funded_txo_count: number;
    funded_txo_sum: number;
    spent_txo_count: number;
    spent_txo_sum: number;
    tx_count: number;
}

export interface IAddress {
    chain_stats: ChainStats;
    mempool_stats: MempoolStats;
    tokens: Record<string, number>
}

export interface UTXO {
    block_pos: number;
    value: number;
    txid: string;
    vout: number;
    status: 'confirmed' | 'unconfirmed';
}
