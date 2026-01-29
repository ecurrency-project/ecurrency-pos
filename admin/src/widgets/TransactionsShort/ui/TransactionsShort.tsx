import {memo} from "react";
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

    const { data: mempoolRecentTransactions } = useGetMempoolRecentTransactionsQuery(undefined, {
        pollingInterval: MEMPOOL_RECENT_PULL_INTERVAL,
    });

    if (!mempoolRecentTransactions || !mempoolRecentTransactions.length) {
        return (
            <div className={classNames(cls.Transactions, className)}>
                <h3 className={cls.title}>{`Latest Transactions`}</h3>
                <div className={cls.empty}>{`No transactions found`}</div>
            </div>
        );
    }

    return (
        <div className={classNames(cls.Transactions, className)}>
            <h3 className={cls.title}>{`Latest Transactions`}</h3>
            <TransactionItemHeader txs={mempoolRecentTransactions[0]}/>
            {mempoolRecentTransactions.map((txOverview: TxShort) => (
                    <TransactionItem transaction={txOverview} key={txOverview.txid}/>
                )
            )}
        </div>
    );
});
