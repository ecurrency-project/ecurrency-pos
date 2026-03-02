import type { ITokenInfo } from '@/entities/Token';

import { rtkApi } from '@/shared/api/rtkApi.ts';

const tokenApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getTokenInfo: build.query<ITokenInfo, { tokenId: string }>({
            query: ({ tokenId }) => `/api/tokens-info/${tokenId}`,
        }),
    }),
    overrideExisting: true,
});

export const {
    useGetTokenInfoQuery,
} = tokenApi;
