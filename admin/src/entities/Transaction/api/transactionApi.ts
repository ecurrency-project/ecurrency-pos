import { rtkApi } from '@/shared/api/rtkApi.ts';
import type { ITransaction, TxShort, ISpend } from '../model/types/ITransaction';

const transactionApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getTransaction: build.query<ITransaction, { id: string }>({
            query: ({ id }) => `/api/tx/${id}`,
        }),
        getOutspends: build.query<ISpend[], { txid: string }>({
            query: ({ txid }) => `/api/tx/${txid}/outspends`,
        }),
        getTransactionsByBlock: build.query<ITransaction[], { blockHeight: string, offset?: number }>({
            query: ({ blockHeight, offset = 0 }) => `/api/block/${blockHeight}/txs/${offset}`,
            serializeQueryArgs: (params) => {
                return params.queryArgs.blockHeight
            },
            merge: (currentCache, newItems) => {
                currentCache.push(...newItems)
            },
            forceRefetch: ({ currentArg, previousArg }) => {
                return JSON.stringify(currentArg) !== JSON.stringify(previousArg)
            }
        }),
        getTransactionsByAddress: build.query<ITransaction[], { address: string, chainHash: string }>({
            query: ({ address, chainHash }) => `/api/address/${address}/txs${chainHash ? `/api/chain/${chainHash}` : ''}`,
            serializeQueryArgs: (params) => {
                return params.queryArgs.address
            },
            merge: (currentCache, newItems) => {
                currentCache.push(...newItems)
            },
            forceRefetch: ({ currentArg, previousArg }) => {
                return JSON.stringify(currentArg) !== JSON.stringify(previousArg)
            }
        }),
        getMempoolRecentTransactions: build.query<TxShort[], void>({
            query: () => `/api/mempool/recent`,
        }),
        getFeeEstimate: build.query<Record<string, number>, void>({
            query: () => `/api/fee-estimates`,
        }),
    }),
    overrideExisting: false,
});

export const {
    useGetTransactionsByBlockQuery,
    useGetTransactionsByAddressQuery,
    useGetTransactionQuery,
    useGetMempoolRecentTransactionsQuery,
    useLazyGetOutspendsQuery,
    useGetFeeEstimateQuery,
} = transactionApi;
