import { toBaseUnits } from '@/shared/lib/baseUnits';

interface ChainStatsLike {
    funded_txo_sum: number | string;
    spent_txo_sum: number | string;
}

/** Address balance in base units. Exact for amounts above 2^53. */
export const addressBalanceSat = (stats: ChainStatsLike): bigint =>
    (toBaseUnits(stats.funded_txo_sum) ?? 0n) - (toBaseUnits(stats.spent_txo_sum) ?? 0n);
