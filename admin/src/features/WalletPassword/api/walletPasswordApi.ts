import { rtkApi } from '@/shared/api/rtkApi';

export interface PasswordStatus {
    password_set: boolean;
}

interface SetPasswordParams {
    password: string;
    currentPassword?: string;
}

const toBase64 = (value: string): string =>
    btoa(String.fromCharCode(...new TextEncoder().encode(value)));

const walletPasswordApi = rtkApi.injectEndpoints({
    endpoints: (build) => ({
        getPasswordStatus: build.query<PasswordStatus, void>({
            query: () => '/admin/password',
        }),
        setWalletPassword: build.mutation<unknown, SetPasswordParams>({
            query: ({ password, currentPassword }) => ({
                url: '/admin/password',
                method: 'POST',
                body: { password },
                ...(currentPassword != null && {
                    headers: { Authorization: `Basic ${toBase64(`admin:${currentPassword}`)}` },
                }),
            }),
            async onQueryStarted(_, { dispatch, queryFulfilled }) {
                try {
                    await queryFulfilled;
                    dispatch(
                        walletPasswordApi.util.updateQueryData('getPasswordStatus', undefined, (draft) => {
                            draft.password_set = true;
                        })
                    );
                } catch {
                    /* empty */
                }
            },
        }),
    }),
    overrideExisting: false,
});

export const { useGetPasswordStatusQuery, useSetWalletPasswordMutation } = walletPasswordApi;
