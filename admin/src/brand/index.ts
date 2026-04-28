import { Logo } from './Logo';

export interface BrandConfig {
    assetId: string;
    assetLabel: string;
    assetName: string;
    addressMainnetRe: RegExp;
    addressTestnetRe: RegExp;
}

export const brand: BrandConfig = {
    assetId: '6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d',
    assetLabel: 'ECR',
    assetName: 'eCurrency',
    addressMainnetRe: /^(?:EC[1-9A-HJ-NP-Za-km-z]{33}|26[k-n][1-9A-HJ-NP-Za-km-z]{49})$/,
    addressTestnetRe: /^(?:Et[1-9A-HJ-NP-Za-km-z]{33}|2A[678][1-9A-HJ-NP-Za-km-z]{49})$/,
};

export { Logo };
