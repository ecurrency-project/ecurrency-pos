import type { TransactionInput, TransactionJSON, TransactionOutput } from '../model/types/types';
import type { AddressData } from '../model/context/SendTransactionContext';
import type { SpendableUtxo, TokenUtxo } from './processUtxos';
import { selectCoins, selectTokenCoins } from './coinSelection';

export interface CreateTokenTransactionParams {
    tokenId: string;
    /** Token amount in base units (from parseTokenAmount). */
    tokenAmount: bigint;
    targetAddress: string;
    changeAddress: string;
    selectedAddresses: string[];
    feeSat: number;
    addressesData?: Record<string, AddressData>;
}

export type CreateTokenTransactionJSONResult =
    | { success: true; data: TransactionJSON }
    | { success: false; error: string };

const outpointToInput = (outpoint: string): TransactionInput => {
    const [txid, voutStr] = outpoint.split(':');
    return { txid, vout: Number(voutStr) };
};

/**
 * Build a token transfer for POST /wallet/transaction/create.
 *
 * Node contract (lib/QBitcoin/REST.pm + Utils.pm::create_txo):
 *  - a token output is `{ "<addr>": <native sat>, token_id, token_amount }`
 *    with exactly ONE address key; native value 0 is allowed;
 *  - one token_id per transaction; Σtoken(in) = Σtoken(out) — the node
 *    rejects burn and mint;
 *  - the fee is implicit: Σnative(in) − Σnative(out);
 *  - token_amount is sent as a decimal STRING (uint64 may exceed 2^53;
 *    Perl numifies integer strings exactly).
 *
 * The client builds both changes itself: token change and native change go to
 * `changeAddress`. Token UTXOs also carry native value — it counts toward the fee.
 */
export const createTokenTransactionJSON = (
    params: CreateTokenTransactionParams
): CreateTokenTransactionJSONResult => {
    const {
        tokenId,
        tokenAmount,
        targetAddress,
        changeAddress,
        selectedAddresses,
        feeSat,
        addressesData,
    } = params;

    if (!tokenId || !targetAddress || !selectedAddresses.length || !changeAddress) {
        return { success: false, error: 'Missing required fields' };
    }

    if (tokenAmount <= 0n) {
        return { success: false, error: 'Invalid amount' };
    }

    if (!Number.isInteger(feeSat) || feeSat <= 0) {
        return { success: false, error: 'Invalid fee' };
    }

    const trimmedTarget = targetAddress.trim();

    const tokenUtxos: TokenUtxo[] = selectedAddresses.flatMap(
        (address) => addressesData?.[address]?.tokens?.[tokenId]?.utxos ?? []
    );

    if (tokenUtxos.length === 0) {
        return { success: false, error: 'No token UTXOs available for selected addresses' };
    }

    const selectedTokenUtxos = selectTokenCoins(tokenUtxos, tokenAmount);
    if (selectedTokenUtxos === null) {
        return { success: false, error: 'Insufficient token balance' };
    }

    const tokenInSum = selectedTokenUtxos.reduce((sum, utxo) => sum + utxo.tokenAmount, 0n);
    const nativeCarriedSat = selectedTokenUtxos.reduce((sum, utxo) => sum + utxo.valueSat, 0);

    // Native inputs are only needed when the token UTXOs don't carry enough
    // native value to pay the fee.
    let selectedNativeUtxos: SpendableUtxo[] = [];
    const deficitSat = feeSat - nativeCarriedSat;
    if (deficitSat > 0) {
        const nativeUtxos = selectedAddresses.flatMap(
            (address) => addressesData?.[address]?.utxos ?? []
        );
        const selected = selectCoins(nativeUtxos, deficitSat);
        if (selected === null) {
            return { success: false, error: 'Insufficient balance for network fee' };
        }
        selectedNativeUtxos = selected;
    }

    const nativeInSum = nativeCarriedSat + selectedNativeUtxos.reduce((sum, utxo) => sum + utxo.valueSat, 0);
    const nativeChangeSat = nativeInSum - feeSat;
    const tokenChange = tokenInSum - tokenAmount;

    // Invariants: Σnative(in) = Σnative(out) + fee; Σtoken(in) = Σtoken(out).
    const outputs: TransactionOutput[] = [];

    if (tokenChange > 0n && changeAddress === trimmedTarget) {
        outputs.push({
            [trimmedTarget]: 0,
            token_id: tokenId,
            token_amount: (tokenAmount + tokenChange).toString(),
        });
    } else {
        outputs.push({
            [trimmedTarget]: 0,
            token_id: tokenId,
            token_amount: tokenAmount.toString(),
        });
        if (tokenChange > 0n) {
            outputs.push({
                [changeAddress]: 0,
                token_id: tokenId,
                token_amount: tokenChange.toString(),
            });
        }
    }

    if (nativeChangeSat > 0) {
        outputs.push({ [changeAddress]: nativeChangeSat });
    }

    const inputs: TransactionInput[] = [
        ...selectedTokenUtxos,
        ...selectedNativeUtxos,
    ].map((utxo) => outpointToInput(utxo.outpoint));

    return { success: true, data: { inputs, outputs } };
};
