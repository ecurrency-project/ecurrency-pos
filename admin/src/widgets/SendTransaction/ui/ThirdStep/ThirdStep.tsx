import { useEffect } from 'react';
import { message } from 'antd';
import classNames from 'classnames';

import {
    useCreateTransactionMutation,
    useSendTransactionMutation,
    useSendTransaction,
} from '@/features/SendTransaction';

import { VStack } from '@/shared/ui/Stack';

import cls from './ThirdStep.module.css';

export const ThirdStep = () => {
    const { transactionJSON, transactionStatus, setTransactionStatus } = useSendTransaction();

    const [checkTransaction] = useCreateTransactionMutation();
    const [confirmTransaction] = useSendTransactionMutation();

    useEffect(() => {
        const sendTransactionData = async () => {
            if (!transactionJSON) return;

            try {
                const created = await checkTransaction({
                    ...transactionJSON,
                }).unwrap();

                await confirmTransaction({ hex: created.hex }).unwrap();
                setTransactionStatus('finish');
                message.success('Transaction sent successfully!');
            } catch {
                setTransactionStatus('error');
                message.error('Failed to send transaction');
            }
        };

        sendTransactionData();
    }, [transactionJSON, setTransactionStatus, checkTransaction, confirmTransaction]);

    return (
        <VStack className={cls.third} gap='md'>
            <div className={cls.statusContainer}>
                <h3>Transaction Status</h3>
                <div className={classNames(cls.status, cls[`${transactionStatus}Color`])}>
                    {transactionStatus === 'process' && 'Processing...'}
                    {transactionStatus === 'finish' && 'Transaction completed successfully!'}
                    {transactionStatus === 'error' && 'Transaction failed. Please try again.'}
                </div>
            </div>
        </VStack>
    );
};
