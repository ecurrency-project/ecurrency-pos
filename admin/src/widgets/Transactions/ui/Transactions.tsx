import { memo } from 'react';
import { useTranslation } from 'react-i18next';
import classNames from 'classnames';

import { type ITransaction, TxBox } from '@/entities/Transaction';

import { Button } from '@/shared/ui/Button';

import ExpandMoreIcon from "@/shared/assets/icons/expand_more.svg?react";

import cls from './Transactions.module.css';

interface TransactionsProps {
    className?: string;
    isTitleVisible?: boolean;
    totalTxs?: number;
    txs?: ITransaction[];
    loadMore?: () => void;
}

export const Transactions = memo(function Transactions(props: TransactionsProps) {
    const {
        className,
        isTitleVisible,
        totalTxs = 0,
        txs = [],
        loadMore,
    } = props;
    const { t } = useTranslation();

    return (
        <div className={classNames(cls.Transactions, className)}>
            {isTitleVisible && <h2 className={cls.title}>{txs?.length} {txs.length < totalTxs && t('_of_transactions', { totalTxs })}</h2>}
            {txs.map((tx) => (
                <TxBox key={tx.txid} tx={tx}/>
            ))}

            {txs.length < totalTxs &&
                <Button
                    className={cls.loadMore}
                    onClick={loadMore}
                    icon={<ExpandMoreIcon />}
                    >
                        {t('_load_more')}
                </Button>
            }
        </div>
    )
});
