import { rtkApi } from '@/shared/api/rtkApi';

import type {
    AddAddressParams,
    EditStakedParams,
    GenerateAddressParams,
    GeneratedAddress,
    IMyAddress,
} from '../model/types/myAddress';

const myAddressApi = rtkApi
    .enhanceEndpoints({ addTagTypes: ['MyAddresses'] })
    .injectEndpoints({
        endpoints: (build) => ({
            getMyAddresses: build.query<IMyAddress[], void>({
                query: () => '/wallet/my_addresses',
                providesTags: ['MyAddresses'],
            }),
            generateNewAddress: build.mutation<GeneratedAddress, GenerateAddressParams | void>({
                query: (params) => ({
                    url: '/wallet/my_address/new',
                    method: 'POST',
                    ...(params?.delegate_pubkeyhash ? { body: params } : {}),
                }),
            }),
            addAddress: build.mutation<IMyAddress, AddAddressParams>({
                query: (body) => ({
                    url: '/wallet/my_address/add',
                    method: 'POST',
                    body,
                }),
                invalidatesTags: ['MyAddresses'],
            }),
            editAddressStaked: build.mutation<void, EditStakedParams>({
                query: ({ address, staked }) => ({
                    url: `/wallet/my_address/${address}/edit`,
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
