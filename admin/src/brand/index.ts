import type { ComponentType, SVGProps } from 'react';

import { Logo } from './Logo';

export interface BrandConfig {
    assetLabel: { main: string; testnet: string };
    assetName: string;
    addressMainnetRe: RegExp;
    addressTestnetRe: RegExp;
    logoSize: { width: number; height: number };
    accent?: { light: string; dark: string };
    CoinIcon?: ComponentType<SVGProps<SVGSVGElement>>;
    powChain?: {
        label: string;
        explorerTxUrl: { main: string; testnet: string };
    };
}

export const brand: BrandConfig = {
    assetLabel: { main: 'ECR', testnet: 'tECR' },
    assetName: 'eCurrency',
    addressMainnetRe: /^(?:EC[1-9A-HJ-NP-Za-km-z]{33}|26[k-n][1-9A-HJ-NP-Za-km-z]{49})$/,
    addressTestnetRe: /^(?:Et[1-9A-HJ-NP-Za-km-z]{33}|2A[678][1-9A-HJ-NP-Za-km-z]{49})$/,
    logoSize: { width: 127, height: 50 },
};

export { Logo };
