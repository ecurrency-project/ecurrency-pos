import type { AxiosInstance } from 'axios'

import type { BlocksSchema } from '@/entities/Block';

import { rtkApi } from '@/shared/api/rtkApi.ts';

export interface StateSchema {
    blocks: BlocksSchema;
    [rtkApi.reducerPath]: ReturnType<typeof rtkApi.reducer>;
}

export interface ThunkExtraArg {
    api: AxiosInstance,
}

export interface ThunkConfig<T> {
    extra: ThunkExtraArg
    rejectValue: T
    state: StateSchema
}
