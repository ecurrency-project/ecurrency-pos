import {memo} from "react";
import classNames from "classnames";

import type { TxShort } from '@/entities/Transaction';

import cls from './TransactionItemHeader.module.css'

interface TransactionItemHeaderProps {
    className?: string;
    txs: TxShort
}

export const TransactionItemHeader = memo(function TransactionItemHeader(props: TransactionItemHeaderProps) {
    const {
        className,
        txs
    } = props;

    return (
        <div className={classNames(cls.TransactionItemHeader, className)}>
            <div className={cls.txCell}>{`Transaction ID`}</div>
            {txs?.value && <div className={cls.txCell}>{`Value`}</div>}
            <div className={cls.txCell}>{`Size`}</div>
            <div className={cls.txCell}>{`Fee`}</div>
        </div>
    );
});
