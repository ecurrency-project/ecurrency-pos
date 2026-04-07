import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import classNames from 'classnames';
import { Tooltip } from 'antd';

import { Transactions } from '@/widgets/Transactions';

import { useGetTipHeightQuery } from '@/entities/TipHeight';
import { useGetTransactionQuery } from '@/entities/Transaction';

import { Clipboard } from '@/shared/ui/Clipboard';
import { HStack, VStack } from '@/shared/ui/Stack';
import { formatNumber, formatSat, formatTime } from '@/shared/utils';
import { TX_POLL_INTERVAL, TX_MIN_CONFIRMATIONS } from '@/shared/const/const';

import CubeIcon from "@/shared/assets/icons/cube.svg?react";

import cls from './TxDetailsPage.module.css';

interface TxDetailsPageProps {
    className?: string;
}

const TxDetailsPage = (props: TxDetailsPageProps) => {
    const { className } = props;
    const { id } = useParams<{ id: string }>();
    const { data: tipHeight = 0 } = useGetTipHeightQuery();
    const { data: transaction, isLoading } = useGetTransactionQuery({ id: id as string });
    const [useUTC, setUseUTC] = useState<boolean>(false);

    const confirmations = transaction?.status?.confirmed && tipHeight
        ? tipHeight - transaction.status.block_height + 1
        : 0;

    const pollingInterval = !transaction?.status?.confirmed || confirmations < TX_MIN_CONFIRMATIONS
        ? TX_POLL_INTERVAL
        : 0;

    useGetTransactionQuery({ id: id as string }, { pollingInterval });

    const confirmationText = !transaction?.status?.confirmed
        ? 'Unconfirmed'
        : confirmations > 0
            ? `${confirmations} Confirmations`
            : 'Confirmed';
    const feerate = transaction && transaction.fee ? transaction.fee / transaction.size : null;

    if (isLoading) {
        return <div className={classNames(cls.TxDetailsPage, 'container', className)}>Loading...</div>
    }

    if (!transaction) {
        return <div className={classNames(cls.TxDetailsPage, 'container', className)}>Transaction not found</div>
    }

    return (
        <div className={classNames(cls.TxDetailsPage, 'container', className)}>
            <VStack gap='sm'>
                <HStack>
                    <CubeIcon fill='#ffbb00' width='50px' height='50px'/>
                    <h1 className={cls.title}>Transaction</h1>
                </HStack>
                <Clipboard text={id as string}/>
            </VStack>

            <VStack justify='space-between' className={cls.statsTable}>
                <HStack justify='space-between' className={cls.statsTableItem}>
                    <span>Status</span>
                    <span>{confirmationText}</span>
                </HStack>
                {transaction.status.confirmed && (
                    <>
                        <HStack justify='space-between' className={cls.statsTableItem}>
                            <span>Included in Block</span>
                            <Link to={`/blocks/${transaction.status.block_hash}`} className={cls.link}>{transaction.status.block_hash}</Link>
                        </HStack>
                        <HStack justify='space-between' className={cls.statsTableItem}>
                            <span>Block height</span>
                            <span>{transaction.status.block_height}</span>
                        </HStack>
                        <HStack justify='space-between' className={cls.statsTableItem}>
                            <span>Block timestamp</span>
                            <Tooltip title={useUTC ? 'Show local time' : 'Show UTC time'} placement="top">
                                <span onClick={() => setUseUTC(!useUTC)} style={{cursor: 'pointer'}}>{formatTime(transaction.status.block_time, useUTC)}</span>
                            </Tooltip>
                        </HStack>
                    </>
                )}

                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Transaction fees</span>
                    <span className="amount">{formatSat(transaction.fee)} ({feerate?.toFixed(1) || 0} sat/B)</span>
                </HStack>

                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Size</span>
                    <span className="amount">{formatNumber(transaction.size)} B</span>
                </HStack>

                {transaction.token_id ? <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Token ID</span>
                    <Link to={`/tx/${transaction.token_id}`} className="mono">{transaction.token_id}</Link>
                </HStack> : null}
            </VStack>

            {!isLoading && transaction && <Transactions
                txs={[transaction]}
                isTitleVisible={false}
            />}
        </div>
    );
}

export default TxDetailsPage;
