import { rtkApi } from '@/shared/api/rtkApi.ts';

export interface StateSchema {
    [rtkApi.reducerPath]: ReturnType<typeof rtkApi.reducer>;
}
