import { memo } from "react";
import { Link } from 'react-router-dom';

import type { TxShort } from '@/entities/Transaction';

import { formatNumber, formatSat } from "@/shared/utils";

import cls from './TransactionItem.module.css'

interface TransactionItemProps {
    className?: string;
    transaction: TxShort
}

export const TransactionItem = memo(function TransactionItem(props: TransactionItemProps) {
    const {
        className,
        transaction
    } = props;

    const feerate = transaction.fee / transaction.size;

    return (
        <div className={className}>
            <Link className={cls.txRow} to={`/tx/${transaction.txid}`}>
                <div className={cls.txCell} data-label={`TXID`}>{transaction.txid}</div>
                <div className={cls.txCell} data-label={`Value`}>
                    {transaction.value !== null ? formatSat(transaction.value) : ''}
                </div>
                <div className={cls.txCell} data-label={`Size`}>
                    {`${formatNumber(transaction.size)} B`}
                </div>
                <div className={cls.txCell} data-label={`Fee`}>
                    {`${feerate.toFixed(1)} sat/B`}
                </div>
            </Link>
        </div>
    )

})
