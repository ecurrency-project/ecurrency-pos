import {memo} from "react";
import { useTranslation } from 'react-i18next';
import { Card } from 'antd';
import classNames from "classnames";

import {
    useGetMempoolRecentTransactionsQuery,
    TransactionItemHeader,
    TransactionItem,
    type TxShort
} from '@/entities/Transaction';

import { MEMPOOL_RECENT_PULL_INTERVAL } from "@/shared/const/const";

import cls from './Transactions.module.css'

interface TransactionsProps {
    className?: string;
}

export const TransactionsShort = memo(function TransactionsShort(props: TransactionsProps) {
    const {
        className,
    } = props;

    const { t } = useTranslation();

    const { data: mempoolRecentTransactions } = useGetMempoolRecentTransactionsQuery(undefined, {
        pollingInterval: MEMPOOL_RECENT_PULL_INTERVAL,
    });

    if (!mempoolRecentTransactions || !mempoolRecentTransactions.length) {
        return (
            <Card className={classNames(cls.Transactions, className)}>
                <div className={cls.header}>
                    <span className={cls.headerTitle}>{t('Latest Transactions')}</span>
                </div>
                <div className={cls.empty}>{`No transactions found`}</div>
            </Card>
        );
    }

    return (
        <Card className={classNames(cls.Transactions, className)}>
            <div className={cls.header}>
                <span className={cls.headerTitle}>{t('Latest Transactions')}</span>
            </div>
            <TransactionItemHeader txs={mempoolRecentTransactions[0]}/>
            {mempoolRecentTransactions.map((txOverview: TxShort) => (
                    <TransactionItem transaction={txOverview} key={txOverview.txid}/>
                )
            )}
        </Card>
    );
});
