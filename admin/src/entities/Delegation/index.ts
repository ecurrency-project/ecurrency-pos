export type {
    IStakingKey,
    IDelegation,
    AddDelegationParams,
    NewStakingKeyResult,
} from './model/types/delegation';
export {
    useGetStakingKeysQuery,
    useNewStakingKeyMutation,
    useGetDelegationsQuery,
    useAddDelegationMutation,
    useRemoveDelegationMutation,
} from './api/delegationApi';
