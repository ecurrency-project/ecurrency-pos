import type { TransactionInput, TransactionJSON } from '../model/types/types';
import type { AddressData } from '../model/context/SendTransactionContext';

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

    const totalSelectedBalance = selectedAddresses.reduce((total, address) => {
        return total + (addressesData?.[address]?.balance || 0);
    }, 0);

    const changeSat = totalSelectedBalance - amountSat - feeSat;

    if (changeSat < 0) {
        return { success: false, error: 'Insufficient balance' };
    }

    // Outputs — an array of objects {address: value_in_satoshis}
    const outputs: Record<string, number>[] = [];

    if (changeSat > 0 && changeAddress === targetAddress.trim()) {
        outputs.push({ [targetAddress.trim()]: amountSat + changeSat });
    } else {
        outputs.push({ [targetAddress.trim()]: amountSat });
        if (changeSat > 0) {
            outputs.push({ [changeAddress]: changeSat });
        }
    }

    // Inputs — an array {txid, vout} of UTXO strings in the format "txid:vout"
    const inputs: TransactionInput[] = [];

    for (const address of selectedAddresses) {
        const data = addressesData?.[address];
        if (!data) continue;

        for (const utxo of data.utxos) {
            const [txid, voutStr] = utxo.split(':');
            inputs.push({ txid, vout: Number(voutStr) });
        }
    }

    if (inputs.length === 0) {
        return { success: false, error: 'No UTXOs available for selected addresses' };
    }

    return { success: true, data: { inputs, outputs } };
};
