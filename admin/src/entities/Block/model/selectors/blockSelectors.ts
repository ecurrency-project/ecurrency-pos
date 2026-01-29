import type { StateSchema } from '@/app/providers/StoreProvider';

export const getBlocksData = (state: StateSchema) => state.blocks?.entities;
export const getBlocksLoading = (state: StateSchema) => state.blocks?.isLoading;
