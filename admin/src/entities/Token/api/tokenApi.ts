import type { ITokenInfo, TokenTransfer } from '@/entities/Token';

import { rtkApi } from '@/shared/api/rtkApi.ts';

const tokenApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getTokenInfo: build.query<ITokenInfo, { tokenId: string }>({
            query: ({ tokenId }) => `/api/tokens-info/${tokenId}`,
        }),
        getTokenTransfersByAddress: build.query<TokenTransfer[], { address: string; tokenId: string; lastSeen?: string }>({
            query: ({ address, tokenId, lastSeen }) =>
                `/api/address/${address}/transfers/${tokenId}${lastSeen ? `/chain/${lastSeen}` : ''}`,
        }),
    }),
    overrideExisting: true,
});

export const {
    useGetTokenInfoQuery,
    useGetTokenTransfersByAddressQuery,
    useLazyGetTokenTransfersByAddressQuery,
} = tokenApi;
