import { useEffect, useState } from 'react';
import { message } from 'antd';
import classNames from 'classnames';

import {
    useCreateTransactionMutation,
    useSendTransactionMutation,
    useSendTransaction,
} from '@/features/SendTransaction';

import { VStack } from '@/shared/ui/Stack';

import cls from './ThirdStep.module.css';

/**
 * Extract a readable message from an RTK Query error. The node's REST answers
 * errors as plain text, so fetchBaseQuery reports them as PARSING_ERROR with
 * the raw body in `data`; 409 means the wallet is locked.
 */
const describeError = (e: unknown): string => {
    const err = e as { status?: number | string; originalStatus?: number; data?: unknown } | undefined;
    const httpStatus = typeof err?.status === 'number' ? err.status : err?.originalStatus;

    if (httpStatus === 409) {
        return 'The wallet is locked — unlock it by enabling staking (or via qecurrency-cli walletunlock) and try again.';
    }

    if (typeof err?.data === 'string' && err.data.trim()) {
        return err.data.trim();
    }
    if (err?.data && typeof err.data === 'object' && 'error' in err.data && typeof err.data.error === 'string') {
        return err.data.error;
    }

    return 'Failed to send transaction';
};

export const ThirdStep = () => {
    const { transactionJSON, feeSat, transactionStatus, setTransactionStatus } = useSendTransaction();
    const [errorText, setErrorText] = useState('');

    const [checkTransaction] = useCreateTransactionMutation();
    const [confirmTransaction] = useSendTransactionMutation();

    useEffect(() => {
        const sendTransactionData = async () => {
            if (!transactionJSON) return;

            try {
                const created = await checkTransaction({
                    ...transactionJSON,
                }).unwrap();

                // The node derives the fee as Σ(inputs) − Σ(outputs); it must
                // match what the user confirmed on the previous step.
                if (created.fee !== feeSat) {
                    setErrorText(`Fee mismatch: the node computed ${created.fee} sat, expected ${feeSat} sat. Transaction was not sent.`);
                    setTransactionStatus('error');
                    message.error('Fee mismatch — transaction was not sent');
                    return;
                }

                await confirmTransaction({ hex: created.hex }).unwrap();
                setTransactionStatus('finish');
                message.success('Transaction sent successfully!');
            } catch (e) {
                setErrorText(describeError(e));
                setTransactionStatus('error');
                message.error('Failed to send transaction');
            }
        };

        sendTransactionData();
        // feeSat is intentionally not a dependency: it is fixed by the time the
        // wizard reaches this step, and re-running the effect would re-send.
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [transactionJSON, setTransactionStatus, checkTransaction, confirmTransaction]);

    return (
        <VStack className={cls.third} gap='md'>
            <div className={cls.statusContainer}>
                <h3>Transaction Status</h3>
                <div className={classNames(cls.status, cls[`${transactionStatus}Color`])}>
                    {transactionStatus === 'process' && 'Processing...'}
                    {transactionStatus === 'finish' && 'Transaction completed successfully!'}
                    {transactionStatus === 'error' && (errorText || 'Transaction failed. Please try again.')}
                </div>
            </div>
        </VStack>
    );
};
