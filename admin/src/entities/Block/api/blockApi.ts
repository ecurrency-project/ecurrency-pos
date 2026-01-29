import { rtkApi } from '@/shared/api/rtkApi.ts';
import type { IBlock } from '../model/types/IBlock.ts';

const blockApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getBlock: build.query<IBlock, { id: string }>({
            query: ({ id }) => `/block/${id}`,
        }),
    }),
    overrideExisting: false,
});

export const {
    useGetBlockQuery,
} = blockApi;
