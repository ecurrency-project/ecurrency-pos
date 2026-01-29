import { useCallback, useState } from 'react';
import { useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import classNames from 'classnames';

import { Transactions } from '@/widgets/Transactions';

import { useGetAddressQuery } from '@/entities/Address';
import { useGetTransactionsByAddressQuery } from '@/entities/Transaction';

import { HStack, VStack } from '@/shared/ui/Stack';
import { QrCode } from '@/shared/ui/QrCode';
import { Clipboard } from '@/shared/ui/Clipboard';

import { formatNumber, formatSat } from '@/shared/utils';

import cls from './AddressPage.module.css';

interface AddressPageProps {
    className?: string
}

const fmtTxos = (count: number, sum: number, t: TFunction<'translation', undefined>) =>
    (count > 0 ? t("outputs", { count }) : t`_no_outputs`)
    + (sum > 0 ? ` (${formatSat(sum)})` : '');

const AddressPage = (props: AddressPageProps) => {
    const { className } = props;
    const { id } = useParams<{ id: string }>();
    const { t } = useTranslation();
    const [chainHash, setChainHash] = useState<string>('');

    const {
        data: address,
        isLoading: addressLoading
    } = useGetAddressQuery({ id: id as string }, {
        refetchOnMountOrArgChange: true,
    });
    const {
        data: transactionsByAddress,
        isLoading: transactionsIsLoading
    } = useGetTransactionsByAddressQuery({ address: id as string, chainHash });

    const handleLoadMore = useCallback(() => {
        setChainHash(transactionsByAddress?.[transactionsByAddress.length - 1].txid || '');
    }, [transactionsByAddress]);

    const chainUtxoCount = address && address?.chain_stats.funded_txo_count - address?.chain_stats.spent_txo_count || 0;
    const chainUtxoSum = address && address?.chain_stats.funded_txo_sum - address?.chain_stats.spent_txo_sum || 0;

    if (addressLoading) {
        return <div className={classNames(cls.AddressPage, 'container', className)}>{t`_loading`}</div>
    }

    if (!address) {
        return <div className={classNames(cls.AddressPage, 'container', className)}>{t`_not_found_address`}</div>
    }

    return (
        <div className={classNames(cls.AddressPage, 'container', className)}>
            <HStack gap='sm' justify='space-between'>
                <VStack gap='sm'>
                    <h1 className={cls.title}>{t`_address`}</h1>
                    <Clipboard className={cls.clipboard} text={id as string}/>
                </VStack>
                <QrCode value={id as string} />
            </HStack>

            <VStack className={cls.statsTable}>
                {address.chain_stats.tx_count > 0 && (
                    <HStack justify='space-between' className={cls.statsTableItem}>
                        <span>{t`_confirmed_tx_count`}</span>
                        <span>{formatNumber(address.chain_stats.tx_count)}</span>
                    </HStack>
                )}

                {address.chain_stats.funded_txo_count > 0 && (
                    <HStack justify='space-between' className={cls.statsTableItem}>
                        <span>{t`_confirmed_received`}</span>
                        <span>{fmtTxos(address.chain_stats.funded_txo_count, address.chain_stats.funded_txo_sum, t)}</span>
                    </HStack>
                )}

                {address.chain_stats.spent_txo_count > 0 && (
                    <HStack justify='space-between' className={cls.statsTableItem}>
                        <span>{t`Confirmed spent`}</span>
                        <span>{fmtTxos(address.chain_stats.spent_txo_count, address.chain_stats.spent_txo_sum, t)}</span>
                    </HStack>
                )}

                {address.chain_stats.tx_count > 0 && (
                    <HStack justify='space-between' className={cls.statsTableItem}>
                        <span>{t`Confirmed unspent`}</span>
                        <span>{fmtTxos(chainUtxoCount, chainUtxoSum, t)}</span>
                    </HStack>
                )}
            </VStack>

            {!transactionsIsLoading && <Transactions
                txs={transactionsByAddress}
                totalTxs={address.chain_stats.tx_count}
                isTitleVisible
                loadMore={handleLoadMore}
            />}
        </div>
    )
}

export default AddressPage;
