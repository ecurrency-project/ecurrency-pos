import { rtkApi } from '@/shared/api/rtkApi.ts';
import type { IAddress } from '@/entities/Address';

const addressApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getAddress: build.query<IAddress, { id: string }>({
            query: ({ id }) => `/address/${id}`,
        }),
    }),
    overrideExisting: true,
});

export const {
    useGetAddressQuery,
} = addressApi;
