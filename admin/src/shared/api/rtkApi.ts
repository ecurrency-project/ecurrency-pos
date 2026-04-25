import { createApi, fetchBaseQuery } from '@reduxjs/toolkit/query/react';


export const rtkApi = createApi({
    reducerPath: 'rtkApi',
    baseQuery: fetchBaseQuery({ baseUrl: '/', headers: { 'Content-Type': 'application/json' } }),
    endpoints: () => ({}),
});
