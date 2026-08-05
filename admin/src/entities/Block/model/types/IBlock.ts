import type { EntityState } from '@reduxjs/toolkit';

import type { BaseUnits } from '@/shared/lib/baseUnits';

export interface IBlock {
    id: string;
    size: number;

    block_weight: BaseUnits;

    previousblockhash: string;
    height: number;
    merkle_root: string;
    weight: BaseUnits;
    tx_count: number;
    timestamp: number;
}

export interface BlocksSchema extends EntityState<IBlock, string> {
    isLoading: boolean;
    error?: string | undefined;
}

export interface BlocksStatus {
    in_best_chain: boolean;
    next_best?: string;
    height: string;
}
