import { rtkApi } from '@/shared/api/rtkApi';

import type { IPeer } from '../model/types/peer';

const peerApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getPeers: build.query<IPeer[], void>({
            query: () => '/peers',
        }),
    }),
});

export const { useGetPeersQuery } = peerApi;
