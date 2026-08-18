import type { BaseUnits } from '@/shared/lib/baseUnits';

export type TxType =
    | 'standard'
    | 'stake'
    | 'coinbase'
    | 'tokens'
    | 'slashing'
    | 'burn'
    | 'downgrade'
    | 'upgrade_stop';

export interface CoinbaseInfo {
    block_height: number;
    tx_hash: string;
    out_num: number;
    value: BaseUnits;
}

export interface DowngradeInfo {
    freeze_txid: string;
    freeze_vout: number;
    btc_txid: string;
    btc_vout: number;
    btc_value: BaseUnits;
    btc_scriptpubkey: string;
}

export interface BurnInfo {
    btc_txid: string;
    btc_block_hash: string;
}

const LABELS: Record<TxType, string> = {
    standard: 'Standard',
    stake: 'Stake',
    coinbase: 'Coinbase',
    tokens: 'Tokens',
    slashing: 'Slashing',
    burn: 'Burn',
    downgrade: 'Downgrade',
    upgrade_stop: 'Upgrade stop',
};

const AMOUNT_ROW_LABELS: Partial<Record<TxType, string>> = {
    burn: 'Burned',
    slashing: 'Slashing fine',
    coinbase: 'Conversion fee',
};

const known = (type?: string): TxType | undefined =>
    type && type in LABELS ? type as TxType : undefined;

export const txTypeLabel = (type?: string): string => LABELS[known(type) ?? 'standard'];

export const isNonStandardType = (type?: string): boolean => {
    const type_ = known(type);
    return type_ !== undefined && type_ !== 'standard';
};

export const txAmountRowLabel = (type?: string): string =>
    AMOUNT_ROW_LABELS[known(type) ?? 'standard'] ?? 'Transaction fees';

export const hasFeeRate = (type?: string): boolean => {
    const type_ = known(type);
    return type_ === undefined || type_ === 'standard' || type_ === 'stake' || type_ === 'tokens';
};

export const isDowngradeInfo = (info: DowngradeInfo | BurnInfo): info is DowngradeInfo =>
    'freeze_txid' in info;
