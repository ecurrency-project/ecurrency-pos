import type { SpendableUtxo, TokenUtxo } from './processUtxos';
import { selectCoins, selectTokenCoins } from './coinSelection';

const INPUT_SIZE_BYTES = 148;
const OUTPUT_SIZE_BYTES = 34;
const TX_OVERHEAD_BYTES = 10;
const OUTPUT_COUNT = 2;
// Token tx: target + token change + native change
const TOKEN_TX_OUTPUT_COUNT = 3;
// Each token output carries a ~9-byte transfer payload (+varstr length)
const TOKEN_OUTPUT_DATA_BYTES = 10;
const TOKEN_TX_EXTRA_BYTES = 2 * TOKEN_OUTPUT_DATA_BYTES;

const DEFAULT_CONFIRMATION_TARGET = '3';
const FALLBACK_CONFIRMATION_TARGET = '1';

export const getDefaultFeeRate = (feeEstimate?: Record<string, number>): number | undefined => {
    if (!feeEstimate) return undefined;

    const rate = feeEstimate[DEFAULT_CONFIRMATION_TARGET]
        ?? feeEstimate[FALLBACK_CONFIRMATION_TARGET]
        ?? Object.values(feeEstimate)[0];

    return rate && rate > 0 ? rate : undefined;
};

export const minRelayFeeSat = (
    inputCount: number,
    feeRate: number,
    opts?: { outputCount?: number; extraBytes?: number },
): number => {
    const outputCount = opts?.outputCount ?? OUTPUT_COUNT;
    const extraBytes = opts?.extraBytes ?? 0;
    const estimatedSize =
        inputCount * INPUT_SIZE_BYTES + outputCount * OUTPUT_SIZE_BYTES + TX_OVERHEAD_BYTES + extraBytes;

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

/**
 * Suggested total fee (sat) for a TOKEN transfer: inputs = the token UTXOs the
 * largest-first selection would spend (they also carry native value) + any
 * native UTXOs needed to cover the fee itself. Adding a native input enlarges
 * the tx and raises the minimum fee, so iterate to a fixed point.
 */
export const suggestTokenFeeSat = (params: {
    tokenUtxos: readonly TokenUtxo[];
    nativeUtxos: readonly SpendableUtxo[];
    tokenAmount: bigint;
    feeRate: number;
}): number => {
    const { tokenUtxos, nativeUtxos, tokenAmount, feeRate } = params;

    const tokenSelected = selectTokenCoins(tokenUtxos, tokenAmount) ?? [...tokenUtxos];
    const tokenInputCount = Math.max(1, tokenSelected.length);
    const nativeCarriedSat = tokenSelected.reduce((sum, utxo) => sum + utxo.valueSat, 0);
    const opts = { outputCount: TOKEN_TX_OUTPUT_COUNT, extraBytes: TOKEN_TX_EXTRA_BYTES };

    let fee = minRelayFeeSat(tokenInputCount, feeRate, opts);
    let extraInputCount = 0;

    for (let i = 0; i < 5; i++) {
        const deficitSat = fee - nativeCarriedSat;
        const selected = deficitSat > 0 ? selectCoins(nativeUtxos, deficitSat) : [];
        // Not enough native to cover the fee: report the current estimate,
        // the transaction builder will fail with a clear error anyway.
        if (selected === null) break;
        if (selected.length === extraInputCount && i > 0) break;
        extraInputCount = selected.length;
        const next = minRelayFeeSat(tokenInputCount + extraInputCount, feeRate, opts);
        if (next === fee) break;
        fee = next;
    }

    return fee;
};
