import type { SpendableUtxo } from './processUtxos';
import { selectCoins } from './coinSelection';

const INPUT_SIZE_BYTES = 148;
const OUTPUT_SIZE_BYTES = 34;
const TX_OVERHEAD_BYTES = 10;
const OUTPUT_COUNT = 2;

const DEFAULT_CONFIRMATION_TARGET = '3';
const FALLBACK_CONFIRMATION_TARGET = '1';

export const getDefaultFeeRate = (feeEstimate?: Record<string, number>): number | undefined => {
    if (!feeEstimate) return undefined;

    const rate = feeEstimate[DEFAULT_CONFIRMATION_TARGET]
        ?? feeEstimate[FALLBACK_CONFIRMATION_TARGET]
        ?? Object.values(feeEstimate)[0];

    return rate && rate > 0 ? rate : undefined;
};

export const minRelayFeeSat = (inputCount: number, feeRate: number): number => {
    const estimatedSize = inputCount * INPUT_SIZE_BYTES + OUTPUT_COUNT * OUTPUT_SIZE_BYTES + TX_OVERHEAD_BYTES;

    return Math.floor(estimatedSize * feeRate) + 1;
};

export const suggestFeeSat = (params: {
    utxos: readonly SpendableUtxo[];
    amountSat: number;
    feeRate: number;
}): number => {
    const { utxos, amountSat, feeRate } = params;

    const selected = selectCoins(utxos, amountSat) ?? [...utxos];
    const inputCount = Math.max(1, selected.length);

    return minRelayFeeSat(inputCount, feeRate);
};
