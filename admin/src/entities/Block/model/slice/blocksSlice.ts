import { createEntityAdapter, createSlice, type PayloadAction } from "@reduxjs/toolkit";
import { blocksFetch } from "../services/blocksFetch.ts";
import { blockOneFetch } from '../services/blockOneFetch.ts';
import type { IBlock, BlocksSchema } from '../types/IBlock.ts';
import type { StateSchema } from '@/app/providers/StoreProvider';

const blocksAdapter = createEntityAdapter<IBlock, string | number>({
    selectId: (block: IBlock) => block.id,
    sortComparer: (a, b) => b.height - a.height,
});

export const getBlocksAdapterData = blocksAdapter.getSelectors<StateSchema>(
    (state) => state.blocks || blocksAdapter.getInitialState(),
);

const blocksSlice = createSlice({
    name: 'block',
    initialState: blocksAdapter.getInitialState<BlocksSchema>({
        isLoading: false,
        error: undefined as string | undefined,
        entities: {},
        ids: [],
    }),
    reducers: {},
    extraReducers: (builder) => {
        builder.addCase(blocksFetch.pending, (state) => {
            state.isLoading = true;
            state.error = undefined;
        });
        builder.addCase(blocksFetch.fulfilled, (state, action: PayloadAction<IBlock[]>) => {
            state.isLoading = false;
            blocksAdapter.addMany(state, action.payload);
        });
        builder.addCase(blocksFetch.rejected, (state, action) => {
            state.isLoading = false;
            state.error = action.payload;
        });

        builder.addCase(blockOneFetch.pending, (state) => {
            state.isLoading = true;
            state.error = undefined;
        });
        builder.addCase(blockOneFetch.fulfilled, (state, action: PayloadAction<IBlock>) => {
            state.isLoading = false;
            blocksAdapter.addOne(state, action.payload);
        });
        builder.addCase(blockOneFetch.rejected, (state, action) => {
            state.isLoading = false;
            state.error = action.payload;
        });
    },
});

export const { reducer: blocksReducer } = blocksSlice;
