import type { SpendableUtxo } from './processUtxos';

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
