import { createAsyncThunk } from '@reduxjs/toolkit';
import type { ThunkConfig } from '@/app/providers/StoreProvider';

export const tipHeightFetch = createAsyncThunk<number, void, ThunkConfig<number>>(
    'tipHeight/fetch',
    async (_, thunkAPI) => {
        const { rejectWithValue, extra } = thunkAPI;

        try {
            const response = await extra.api.get('/api/blocks/tip/height');
            return response.data
        } catch (err) {
            console.error(err);
            return rejectWithValue(0);
        }
    },
);
