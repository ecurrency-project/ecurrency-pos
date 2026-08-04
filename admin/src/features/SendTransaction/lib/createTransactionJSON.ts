import type { TransactionInput, TransactionJSON, TransactionOutput } from '../model/types/types';
import type { AddressData } from '../model/context/SendTransactionContext';
import { sumUtxoValues } from './processUtxos';
import type { SpendableUtxo } from './processUtxos';
import { selectCoins } from './coinSelection';
import { toWireAmount } from './wireAmount';

export interface CreateTransactionParams {
    targetAddress: string;
    amountSat: bigint;
    feeSat: bigint;
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

    if (amountSat <= 0n) {
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

    const changeSat = sumUtxoValues(selected) - amountSat - feeSat;

    // Outputs — an array of objects {address: value_in_satoshis}
    const outputs: TransactionOutput[] = [];

    if (changeSat > 0n && changeAddress === trimmedTarget) {
        outputs.push({ [trimmedTarget]: toWireAmount(amountSat + changeSat) });
    } else {
        outputs.push({ [trimmedTarget]: toWireAmount(amountSat) });
        if (changeSat > 0n) {
            outputs.push({ [changeAddress]: toWireAmount(changeSat) });
        }
    }

    // Inputs — an array {txid, vout} built from the selected UTXOs
    const inputs: TransactionInput[] = selected.map((utxo) => {
        const [txid, voutStr] = utxo.outpoint.split(':');
        return { txid, vout: Number(voutStr) };
    });

    return { success: true, data: { inputs, outputs } };
};
