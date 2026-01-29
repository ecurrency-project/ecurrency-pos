import { configureStore, type ReducersMapObject } from '@reduxjs/toolkit';

import { $api } from '@/shared/api/api.ts';

import type { StateSchema } from './StateSchema.ts';
import { blocksReducer } from '@/entities/Block';
import { tipHeightReducer } from '@/entities/TipHeight';
import { rtkApi } from '@/shared/api/rtkApi.ts';

export function createReduxStore(initialState?: StateSchema) {
    const rootReducer: ReducersMapObject<StateSchema> = {
        blocks: blocksReducer,
        tipHeight: tipHeightReducer,
        [rtkApi.reducerPath]: rtkApi.reducer,
    };


    const store = configureStore({
        reducer: rootReducer,
        preloadedState: initialState,
        middleware: (getDefaultMiddleware) => getDefaultMiddleware({
            thunk: {
                extraArgument: {
                    api: $api,
                },
            },
        }).concat(rtkApi.middleware)
    });

    return store;
}

export type AppDispatch = ReturnType<typeof createReduxStore>['dispatch'];
