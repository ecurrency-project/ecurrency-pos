import { rtkApi } from '@/shared/api/rtkApi.ts';

import type { BlocksStatus, IBlock } from '../model/types/IBlock.ts';

const blockApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getBlocks: build.query<IBlock[], number | void>({
            query: (startHeight) => startHeight ? `/blocks/${startHeight}` : '/blocks',
        }),
        getBlock: build.query<IBlock, { id: string }>({
            query: ({ id }) => `/api/block/${id}`,
        }),
        getBlockStatus: build.query<BlocksStatus, { id: string }>({
            query: ({ id }) => `/block/${id}/status`,
        }),
    }),
    overrideExisting: false,
});

export const {
    useGetBlocksQuery,
    useLazyGetBlocksQuery,
    useGetBlockQuery,
    useGetBlockStatusQuery,
} = blockApi;
