import type { UTXO } from '@/entities/Address';

export interface SpendableUtxo {
    outpoint: string;
    valueSat: number;
}

export interface TokenUtxo extends SpendableUtxo {
    tokenAmount: bigint;
}

export interface TokenUtxoGroup {
    amount: bigint;
    utxos: TokenUtxo[];
}

interface ProcessedUtxos {
    value: number;
    utxos: SpendableUtxo[];
    tokens: Record<string, TokenUtxoGroup>;
}

const hasTokenData = (utxo: UTXO): boolean =>
    utxo.token_id != null || utxo.token_amount != null || utxo.token_permissions != null;

export const processUtxos = (utxos: UTXO[]): ProcessedUtxos => {
    return utxos.reduce<ProcessedUtxos>(
        (acc, utxo) => {
            if (utxo.status !== 'confirmed') {
                return acc;
            }

            if (hasTokenData(utxo)) {
                if (
                    utxo.token_id &&
                    utxo.token_amount != null &&
                    Number.isInteger(utxo.token_amount) &&
                    !utxo.token_permissions
                ) {
                    let group = acc.tokens[utxo.token_id];
                    if (!group) {
                        group = { amount: 0n, utxos: [] };
                        acc.tokens[utxo.token_id] = group;
                    }
                    const tokenAmount = BigInt(utxo.token_amount);
                    group.amount += tokenAmount;
                    group.utxos.push({
                        outpoint: `${utxo.txid}:${utxo.vout}`,
                        valueSat: utxo.value,
                        tokenAmount,
                    });
                }
                return acc;
            }

            acc.value += utxo.value;
            acc.utxos.push({ outpoint: `${utxo.txid}:${utxo.vout}`, valueSat: utxo.value });
            return acc;
        },
        { value: 0, utxos: [], tokens: {} }
    );
};
