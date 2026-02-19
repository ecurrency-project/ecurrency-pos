import { rtkApi } from '@/shared/api/rtkApi';

import type { AddAddressParams, EditStakedParams, IMyAddress } from '../model/types/myAddress';

const myAddressApi = rtkApi
    .enhanceEndpoints({ addTagTypes: ['MyAddresses'] })
    .injectEndpoints({
        endpoints: (build) => ({
            getMyAddresses: build.query<IMyAddress[], void>({
                query: () => '/my_addresses',
                providesTags: ['MyAddresses'],
            }),
            generateNewAddress: build.mutation<AddAddressParams, void>({
                query: () => ({
                    url: '/my_address/new',
                    method: 'POST',
                }),
            }),
            addAddress: build.mutation<IMyAddress, AddAddressParams>({
                query: (body) => ({
                    url: '/my_address/add',
                    method: 'POST',
                    body,
                }),
                invalidatesTags: ['MyAddresses'],
            }),
            editAddressStaked: build.mutation<void, EditStakedParams>({
                query: ({ address, staked }) => ({
                    url: `/my_address/${address}/edit`,
                    method: 'POST',
                    body: { staked },
                }),
                invalidatesTags: ['MyAddresses'],
            }),
        }),
    });

export const {
    useGetMyAddressesQuery,
    useGenerateNewAddressMutation,
    useAddAddressMutation,
    useEditAddressStakedMutation,
} = myAddressApi;
