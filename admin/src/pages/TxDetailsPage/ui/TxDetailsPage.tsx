import { useState } from 'react';
import { useSelector } from 'react-redux';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import classNames from 'classnames';
import { Tooltip } from 'antd';

import { Transactions } from '@/widgets/Transactions';

import { getTipHeight } from '@/entities/TipHeight';
import { useGetTransactionQuery } from '@/entities/Transaction';

import { Clipboard } from '@/shared/ui/Clipboard';
import { HStack, VStack } from '@/shared/ui/Stack';
import { formatNumber, formatSat, formatTime } from '@/shared/utils';

import CubeIcon from "@/shared/assets/icons/cube.svg?react";

import cls from './TxDetailsPage.module.css';

interface TxDetailsPageProps {
    className?: string;
}

const TxDetailsPage = (props: TxDetailsPageProps) => {
    const { className } = props;
    const { id } = useParams<{ id: string }>();
    const tipHeight = useSelector(getTipHeight);
    const { data: transaction, isLoading } = useGetTransactionQuery({ id: id as string });
    const [useUTC, setUseUTC] = useState<boolean>(false);

    const { t } = useTranslation();

    const confirmationText = !transaction?.status?.confirmed ? 'Unconfirmed' : tipHeight ? `${tipHeight - transaction?.status.block_height + 1} Confirmations` : 'Confirmed';
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
                    <h1 className={cls.title}>{t('Transaction')}</h1>
                </HStack>
                <Clipboard text={id as string}/>
            </VStack>

            <VStack justify='space-between' className={cls.statsTable}>
                <HStack justify='space-between' className={cls.statsTableItem}>
                    <span>{t('Status')}</span>
                    <span>{confirmationText}</span>
                </HStack>
                {transaction.status.confirmed && (
                    <>
                        <HStack justify='space-between' className={cls.statsTableItem}>
                            <span>{t`Included in Block`}</span>
                            <Link to={`/blocks/${transaction.status.block_hash}`} className={cls.link}>{transaction.status.block_hash}</Link>
                        </HStack>
                        <HStack justify='space-between' className={cls.statsTableItem}>
                            <span>{t`Block height`}</span>
                            <span>{transaction.status.block_height}</span>
                        </HStack>
                        <HStack justify='space-between' className={cls.statsTableItem}>
                            <span>{t`Block timestamp`}</span>
                            <Tooltip title={t(useUTC ? '_click_show_local_time' : '_click_show_utc_time')} placement="top">
                                <span onClick={() => setUseUTC(!useUTC)} style={{cursor: 'pointer'}}>{formatTime(transaction.status.block_time, useUTC)}</span>
                            </Tooltip>
                        </HStack>
                    </>
                )}

                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>{t('Transaction fees')}</span>
                    <span className="amount">{formatSat(transaction.fee)} ({feerate?.toFixed(1) || 0} sat/B)</span>
                </HStack>

                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>{t('Size')}</span>
                    <span className="amount">{formatNumber(transaction.size)} B</span>
                </HStack>

                {transaction.token_id ? <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>{t('Token ID')}</span>
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
