import { configureStore, type ReducersMapObject } from '@reduxjs/toolkit';

import type { StateSchema } from './StateSchema.ts';
import { rtkApi } from '@/shared/api/rtkApi.ts';

export function createReduxStore(initialState?: StateSchema) {
    const rootReducer: ReducersMapObject<StateSchema> = {
        [rtkApi.reducerPath]: rtkApi.reducer,
    };

    const store = configureStore({
        reducer: rootReducer,
        preloadedState: initialState,
        middleware: (getDefaultMiddleware) => getDefaultMiddleware().concat(rtkApi.middleware)
    });

    return store;
}
