import type { UTXO } from '@/entities/Address';

export interface SpendableUtxo {
    outpoint: string;
    valueSat: number;
}

interface ProcessedUtxos {
    value: number;
    utxos: SpendableUtxo[];
}

export const processUtxos = (utxos: UTXO[]): ProcessedUtxos => {
    return utxos.reduce(
        (acc, utxo) => {
            if (utxo.status === 'confirmed') {
                acc.value += utxo.value;
                acc.utxos.push({ outpoint: `${utxo.txid}:${utxo.vout}`, valueSat: utxo.value });
            }
            return acc;
        },
        { value: 0, utxos: [] as SpendableUtxo[] }
    );
};
