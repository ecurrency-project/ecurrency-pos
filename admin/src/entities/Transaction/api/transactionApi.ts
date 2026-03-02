import { rtkApi } from '@/shared/api/rtkApi.ts';
import type { ITransaction, TxShort } from '@/entities/Transaction';

const transactionApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getTransaction: build.query<ITransaction, { id: string }>({
            query: ({ id }) => `/api/tx/${id}`,
        }),
        getTransactionsByBlock: build.query<ITransaction[], { blockHeight: string, offset?: number }>({
            query: ({ blockHeight, offset = 0 }) => `/block/${blockHeight}/txs/${offset}`,
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
            query: ({ address, chainHash }) => `/address/${address}/txs${chainHash ? `/chain/${chainHash}` : ''}`,
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
            query: () => `/mempool/recent`,
        }),
    }),
    overrideExisting: false,
});

export const {
    useGetTransactionsByBlockQuery,
    useGetTransactionsByAddressQuery,
    useGetTransactionQuery,
    useGetMempoolRecentTransactionsQuery,
} = transactionApi;
