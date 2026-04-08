import type { UTXO } from '@/entities/Address';

interface ProcessedUtxos {
    value: number;
    utxos: string[];
}

export const processUtxos = (utxos: UTXO[]): ProcessedUtxos => {
    return utxos.reduce(
        (acc, utxo) => {
            if (utxo.status === 'confirmed') {
                acc.value += utxo.value;
                acc.utxos.push(`${utxo.txid}:${utxo.vout}`);
            }
            return acc;
        },
        { value: 0, utxos: [] as string[] }
    );
};
