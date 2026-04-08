import { rtkApi } from '@/shared/api/rtkApi.ts';

import type { IAddress, UTXO } from '@/entities/Address';

const addressApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getAddress: build.query<IAddress, { id: string }>({
            query: ({ id }) => `/api/address/${id}`,
        }),
        getAddressUtxos: build.query<UTXO[], string>({
            query: (address) => `/api/address/${address}/utxo`,
        }),
    }),
    overrideExisting: true,
});

export const {
    useGetAddressQuery,
    useLazyGetAddressUtxosQuery,
} = addressApi;
