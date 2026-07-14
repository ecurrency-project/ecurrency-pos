import type { SpendableUtxo, TokenUtxo } from './processUtxos';

export const selectCoins = (
    utxos: readonly SpendableUtxo[],
    targetSat: number,
): SpendableUtxo[] | null => {
    const sorted = [...utxos].sort((a, b) => b.valueSat - a.valueSat);
    const selected: SpendableUtxo[] = [];
    let sum = 0;

    for (const utxo of sorted) {
        selected.push(utxo);
        sum += utxo.valueSat;
        if (sum >= targetSat) return selected;
    }

    return null;
};

/**
 * Largest-first selection over token UTXOs (base units, BigInt).
 * Mirrors selectCoins; returns null when the token balance is insufficient.
 */
export const selectTokenCoins = (
    utxos: readonly TokenUtxo[],
    target: bigint,
): TokenUtxo[] | null => {
    const sorted = [...utxos].sort((a, b) =>
        a.tokenAmount === b.tokenAmount ? 0 : a.tokenAmount > b.tokenAmount ? -1 : 1
    );
    const selected: TokenUtxo[] = [];
    let sum = 0n;

    for (const utxo of sorted) {
        selected.push(utxo);
        sum += utxo.tokenAmount;
        if (sum >= target) return selected;
    }

    return null;
};
