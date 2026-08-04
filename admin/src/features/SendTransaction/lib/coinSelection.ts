import type { SpendableUtxo, TokenUtxo } from './processUtxos';

const selectLargestFirst = <T>(
    items: readonly T[],
    target: bigint,
    getValue: (item: T) => bigint,
): T[] | null => {
    const sorted = [...items].sort((a, b) => {
        const aValue = getValue(a);
        const bValue = getValue(b);

        return aValue === bValue ? 0 : aValue > bValue ? -1 : 1;
    });
    const selected: T[] = [];
    let sum = 0n;

    for (const item of sorted) {
        selected.push(item);
        sum += getValue(item);
        if (sum >= target) return selected;
    }

    return null;
};

export const selectCoins = (
    utxos: readonly SpendableUtxo[],
    targetSat: bigint,
): SpendableUtxo[] | null =>
    selectLargestFirst(utxos, targetSat, (utxo) => utxo.valueSat);

/**
 * Largest-first selection over token UTXOs (base units).
 * Returns null when the token balance is insufficient.
 */
export const selectTokenCoins = (
    utxos: readonly TokenUtxo[],
    target: bigint,
): TokenUtxo[] | null =>
    selectLargestFirst(utxos, target, (utxo) => utxo.tokenAmount);
