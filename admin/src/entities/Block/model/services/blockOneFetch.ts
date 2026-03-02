import { createAsyncThunk } from '@reduxjs/toolkit';
import { AxiosError } from 'axios';

import type { ThunkConfig } from '@/app/providers/StoreProvider';
import type { IBlock } from '@/entities/Block';

export const blockOneFetch = createAsyncThunk<IBlock, string, ThunkConfig<string>>(
    'block/fetch',
    async (blockHeight, thunkAPI) => {
        const {
            rejectWithValue,
            extra,
        } = thunkAPI;

        try {
            const response = await extra.api.get(`/api/block/${blockHeight}`);
            return response.data;
        } catch (err: unknown) {
            if (err instanceof AxiosError) {
                if (err.response?.data) {
                    return rejectWithValue(err.response.data?.message || 'Error Server');
                }
            }
            return rejectWithValue('Error Server');
        }
    },
);
