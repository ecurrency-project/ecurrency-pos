import { rtkApi } from '@/shared/api/rtkApi';

import type { WalletStatus } from '@/entities/ChainStatus';

interface SetGenerateParams {
    generate: boolean;
}

const stakingToggleApi = rtkApi
    .enhanceEndpoints({ addTagTypes: ['ChainStatus'] })
    .injectEndpoints({
        endpoints: (build) => ({
            setGenerate: build.mutation<WalletStatus, SetGenerateParams>({
                query: (body) => ({
                    url: '/admin/generate',
                    method: 'POST',
                    body,
                }),
                invalidatesTags: ['ChainStatus'],
            }),
        }),
        overrideExisting: false,
    });

export const { useSetGenerateMutation } = stakingToggleApi;
