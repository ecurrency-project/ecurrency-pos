import { createApi, fetchBaseQuery } from '@reduxjs/toolkit/query/react';

import { exactJsonResponseHandler } from './exactJson';


export const rtkApi = createApi({
    reducerPath: 'rtkApi',
    baseQuery: fetchBaseQuery({
        baseUrl: '/',
        headers: { 'Content-Type': 'application/json' },
        responseHandler: exactJsonResponseHandler,
    }),
    endpoints: () => ({}),
});
