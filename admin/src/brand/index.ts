import { Logo } from './Logo';

export interface BrandConfig {
    assetId: string;
    assetLabel: string;
    assetName: string;
    addressMainnetRe: RegExp;
    addressTestnetRe: RegExp;
}

// Generic base58 address regex as a stub.
const BASE58_RE = /^[1-9A-HJ-NP-Za-km-z]{20,80}$/;

export const brand: BrandConfig = {
    assetId: '',
    assetLabel: 'COIN',
    assetName: 'Blockchain',
    addressMainnetRe: BASE58_RE,
    addressTestnetRe: BASE58_RE,
};

export { Logo };
