import { rtkApi } from '@/shared/api/rtkApi.ts';

import type {
    CreateTransactionRequest,
    CreateTransactionResponse,
    SendTransactionRequest,
} from '../model/types/types';

const sendTransactionApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        createTransaction: build.mutation<CreateTransactionResponse, CreateTransactionRequest>({
            query: (data) => ({
                url: '/wallet/transaction/create',
                method: 'POST',
                body: data,
            }),
        }),
        sendTransaction: build.mutation<unknown, SendTransactionRequest>({
            query: (data) => ({
                url: '/wallet/transaction/send',
                method: 'POST',
                body: data,
            }),
        }),
    }),
    overrideExisting: true,
});

export const {
    useCreateTransactionMutation,
    useSendTransactionMutation,
} = sendTransactionApi;
