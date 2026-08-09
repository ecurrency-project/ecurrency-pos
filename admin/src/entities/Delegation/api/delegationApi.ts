import { rtkApi } from '@/shared/api/rtkApi';

import type {
    AddDelegationParams,
    IDelegation,
    IStakingKey,
    NewStakingKeyResult,
} from '../model/types/delegation';

const delegationApi = rtkApi
    .enhanceEndpoints({ addTagTypes: ['StakingKeys', 'Delegations'] })
    .injectEndpoints({
        endpoints: (build) => ({
            getStakingKeys: build.query<IStakingKey[], void>({
                query: () => '/wallet/staking_keys',
                providesTags: ['StakingKeys'],
            }),
            newStakingKey: build.mutation<NewStakingKeyResult, void>({
                query: () => ({
                    url: '/wallet/staking_key/new',
                    method: 'POST',
                }),
                invalidatesTags: ['StakingKeys'],
            }),
            getDelegations: build.query<IDelegation[], void>({
                query: () => '/wallet/delegations',
                providesTags: ['Delegations'],
            }),
            addDelegation: build.mutation<{ address: string }, AddDelegationParams>({
                query: (body) => ({
                    url: '/wallet/delegation/add',
                    method: 'POST',
                    body,
                }),
                invalidatesTags: ['Delegations', 'StakingKeys'],
            }),
            removeDelegation: build.mutation<void, string>({
                query: (address) => ({
                    url: `/wallet/delegation/${address}/remove`,
                    method: 'POST',
                }),
                invalidatesTags: ['Delegations', 'StakingKeys'],
            }),
        }),
    });

export const {
    useGetStakingKeysQuery,
    useNewStakingKeyMutation,
    useGetDelegationsQuery,
    useAddDelegationMutation,
    useRemoveDelegationMutation,
} = delegationApi;
