import { rtkApi } from '@/shared/api/rtkApi';

const tipHeightApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getTipHeight: build.query<number, void>({
            query: () => '/api/blocks/tip/height',
        }),
    }),
});

export const { useGetTipHeightQuery } = tipHeightApi;
