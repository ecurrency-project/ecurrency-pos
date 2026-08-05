import { createContext, useContext } from 'react';

import { brand } from '@/brand';

export type NetworkName = 'main' | 'testnet';

export const resolveNetwork = (chain?: string): NetworkName =>
    chain === 'testnet' || chain === 'regtest' ? 'testnet' : 'main';

export const NetworkContext = createContext<NetworkName>('main');

export const useNetwork = (): NetworkName => useContext(NetworkContext);

export const useAssetLabel = (): string => brand.assetLabel[useNetwork()];
