import type { StateSchema } from '@/app/providers/StoreProvider';

export const getTipHeight = (state: StateSchema) => state.tipHeight.tipHeight;
