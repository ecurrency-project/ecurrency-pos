import { createSlice } from '@reduxjs/toolkit';
import { tipHeightFetch } from '@/entities/TipHeight/model/services/tipHeightFetch.ts';
import type { TipHeightSchema } from '@/entities/TipHeight';

const initialState: TipHeightSchema = {
    tipHeight: 0,
};

export const tipHeightSlice = createSlice({
    name: 'tipHeight',
    initialState,
    reducers: {},
    extraReducers: (builder) => {
        builder.addCase(tipHeightFetch.fulfilled, (state, action) => {
            state.tipHeight = action.payload;
        });
    },
});

export const { reducer: tipHeightReducer } = tipHeightSlice;
