import { rtkApi } from '@/shared/api/rtkApi';

import type { ChainStatus } from '../model/types/chainStatus';

const chainStatusApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getChainStatus: build.query<ChainStatus, void>({
            query: () => '/status',
        }),
    }),
});

export const { useGetChainStatusQuery } = chainStatusApi;
