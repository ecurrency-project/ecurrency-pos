import type { FC, ReactNode } from 'react';
import { Provider } from "react-redux";

import type { StateSchema } from '../config/StateSchema.ts';
import { createReduxStore } from "../config/store.ts";


interface StoreProviderProps {
    children?: ReactNode,
    initialState?: StateSchema
}

export const StoreProvider: FC<StoreProviderProps> = (props) => {
    const {
        children,
        initialState,
    } = props;

    const store = createReduxStore(
        initialState,
    );

    return (
        <Provider store={store}>
            {children}
        </Provider>
    );
};
