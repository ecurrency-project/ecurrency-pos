import type { FC, ReactNode } from 'react';

import { useGetNodeStatusQuery } from '@/entities/ChainStatus';

import { NetworkContext, resolveNetwork } from '@/shared/lib/network';

interface NetworkProviderProps {
    children?: ReactNode;
}

export const NetworkProvider: FC<NetworkProviderProps> = ({ children }) => {
    const { data } = useGetNodeStatusQuery();

    return (
        <NetworkContext.Provider value={resolveNetwork(data?.chain)}>
            {children}
        </NetworkContext.Provider>
    );
};
