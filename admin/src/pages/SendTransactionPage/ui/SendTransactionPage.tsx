import type { CSSProperties } from 'react';
import { Steps } from 'antd';
import classNames from 'classnames';

import { FirstStep, SecondStep, ThirdStep } from '@/widgets/SendTransaction';

import { SendTransactionProvider, useSendTransaction } from '@/features/SendTransaction';

import cls from './SendTransactionPage.module.css';

interface SendTransactionPageProps {
    className?: string;
}

const steps = [
    { key: 'First', title: 'First' },
    { key: 'Second', title: 'Second' },
    { key: 'Last', title: 'Last' },
];

const contentStyle: CSSProperties = {
    height: '400px',
    marginTop: 16,
};

const SendTransactionContent = ({ className }: SendTransactionPageProps) => {
    const { step, transactionStatus } = useSendTransaction();

    return (
        <div className={classNames(cls.SendTransactionPage, 'container', className)}>
            <h1 className={cls.title}>Send Transaction</h1>
            <Steps items={steps} current={step} status={step === 2 ? transactionStatus : undefined} />

            <div style={contentStyle}>
                {step === 0 && <FirstStep />}
                {step === 1 && <SecondStep />}
                {step === 2 && <ThirdStep />}
            </div>
        </div>
    );
};

const SendTransactionPage = (props: SendTransactionPageProps) => {
    return (
        <SendTransactionProvider>
            <SendTransactionContent {...props} />
        </SendTransactionProvider>
    );
};

export default SendTransactionPage;
