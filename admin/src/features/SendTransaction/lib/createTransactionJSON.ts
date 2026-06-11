import type { TransactionInput, TransactionJSON } from '../model/types/types';
import type { AddressData } from '../model/context/SendTransactionContext';
import type { SpendableUtxo } from './processUtxos';
import { selectCoins } from './coinSelection';

export interface CreateTransactionParams {
    targetAddress: string;
    amountSat: number;
    feeSat: number;
    selectedAddresses: string[];
    changeAddress: string;
    addressesData?: Record<string, AddressData>;
}

export type CreateTransactionJSONResult =
    | { success: true; data: TransactionJSON }
    | { success: false; error: string };

export const createTransactionJSON = (params: CreateTransactionParams): CreateTransactionJSONResult => {
    const { targetAddress, amountSat, feeSat, selectedAddresses, changeAddress, addressesData } = params;

    if (!targetAddress || !amountSat || !selectedAddresses.length || !changeAddress) {
        return { success: false, error: 'Missing required fields' };
    }

    if (!Number.isInteger(amountSat) || amountSat <= 0) {
        return { success: false, error: 'Invalid amount' };
    }

    const trimmedTarget = targetAddress.trim();

    const availableUtxos: SpendableUtxo[] = selectedAddresses.flatMap(
        (address) => addressesData?.[address]?.utxos ?? []
    );

    if (availableUtxos.length === 0) {
        return { success: false, error: 'No UTXOs available for selected addresses' };
    }

    const selected = selectCoins(availableUtxos, amountSat + feeSat);
    if (selected === null) {
        return { success: false, error: 'Insufficient balance' };
    }

    const selectedSumSat = selected.reduce((sum, utxo) => sum + utxo.valueSat, 0);

    const changeSat = selectedSumSat - amountSat - feeSat;

    // Outputs — an array of objects {address: value_in_satoshis}
    const outputs: Record<string, number>[] = [];

    if (changeSat > 0 && changeAddress === trimmedTarget) {
        outputs.push({ [trimmedTarget]: amountSat + changeSat });
    } else {
        outputs.push({ [trimmedTarget]: amountSat });
        if (changeSat > 0) {
            outputs.push({ [changeAddress]: changeSat });
        }
    }

    // Inputs — an array {txid, vout} built from the selected UTXOs
    const inputs: TransactionInput[] = selected.map((utxo) => {
        const [txid, voutStr] = utxo.outpoint.split(':');
        return { txid, vout: Number(voutStr) };
    });

    return { success: true, data: { inputs, outputs } };
};
