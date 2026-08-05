import { rtkApi } from '@/shared/api/rtkApi';

import type { ChainStatus } from '../model/types/chainStatus';

const chainStatusApi = rtkApi
    .enhanceEndpoints({ addTagTypes: ['ChainStatus'] })
    .injectEndpoints({
        endpoints: (build) => ({
            getChainStatus: build.query<ChainStatus, void>({
                query: () => '/admin/status',
                providesTags: ['ChainStatus'],
            }),
            getNodeStatus: build.query<ChainStatus, void>({
                query: () => '/api/status',
            }),
        }),
    });

export const { useGetChainStatusQuery, useGetNodeStatusQuery } = chainStatusApi;
