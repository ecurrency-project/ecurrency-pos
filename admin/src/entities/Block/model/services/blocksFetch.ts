import { createAsyncThunk } from "@reduxjs/toolkit";
import { AxiosError } from 'axios';

import type { ThunkConfig } from '@/app/providers/StoreProvider';

import type { IBlock } from '../types/IBlock.ts';

export const blocksFetch = createAsyncThunk<IBlock[], string | number | undefined, ThunkConfig<string>>(
    'blocks/fetch',
    async (blockHeight, thunkAPI) => {
        const {
            rejectWithValue,
            extra,
        } = thunkAPI;

        try {
            const response = await extra.api.get(`/api/blocks${blockHeight ? `/${blockHeight}` : ''}`);
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
