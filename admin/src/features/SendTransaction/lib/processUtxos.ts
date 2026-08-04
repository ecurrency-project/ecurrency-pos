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

const toBaseUnits = (value: unknown): bigint | null => {
    if (typeof value === 'number') {
        return Number.isInteger(value) ? BigInt(value) : null;
    }
    if (typeof value === 'string' && /^\d+$/.test(value.trim())) {
        return BigInt(value.trim());
    }
    return null;
};

const carriesTokens = (utxo: UTXO): boolean =>
    utxo.token_amount != null || utxo.token_permissions != null;

export const processUtxos = (utxos: UTXO[]): ProcessedUtxos => {
    return utxos.reduce<ProcessedUtxos>(
        (acc, utxo) => {
            if (utxo.status !== 'confirmed') {
                return acc;
            }

            const parsedValue = toBaseUnits(utxo.value);
            if (parsedValue === null) {
                return acc;
            }

            const valueSat = Number(parsedValue);

            if (carriesTokens(utxo)) {
                const tokenAmount = toBaseUnits(utxo.token_amount);

                if (utxo.token_id && tokenAmount !== null && !utxo.token_permissions) {
                    let group = acc.tokens[utxo.token_id];
                    if (!group) {
                        group = { amount: 0n, utxos: [] };
                        acc.tokens[utxo.token_id] = group;
                    }
                    group.amount += tokenAmount;
                    group.utxos.push({
                        outpoint: `${utxo.txid}:${utxo.vout}`,
                        valueSat,
                        tokenAmount,
                    });
                }
                return acc;
            }

            acc.value += valueSat;
            acc.utxos.push({ outpoint: `${utxo.txid}:${utxo.vout}`, valueSat });
            return acc;
        },
        { value: 0, utxos: [], tokens: {} }
    );
};
