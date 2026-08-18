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

// Generic base58 address regex as a stub.
const BASE58_RE = /^[1-9A-HJ-NP-Za-km-z]{20,80}$/;

export const brand: BrandConfig = {
    assetLabel: { main: 'COIN', testnet: 'tCOIN' },
    assetName: 'Blockchain',
    addressMainnetRe: BASE58_RE,
    addressTestnetRe: BASE58_RE,
    logoSize: { width: 127, height: 50 },
};

export { Logo };
