import { useCallback, useState } from 'react';
import { useParams } from 'react-router-dom';
import classNames from 'classnames';

import { Transactions } from '@/widgets/Transactions';

import { useGetAddressQuery } from '@/entities/Address';
import { useGetTransactionsByAddressQuery } from '@/entities/Transaction';
import { TokenItem } from '@/entities/Token';

import { HStack, VStack } from '@/shared/ui/Stack';
import { QrCode } from '@/shared/ui/QrCode';
import { Clipboard } from '@/shared/ui/Clipboard';

import { formatNumber, formatSat } from '@/shared/utils';

import cls from './AddressPage.module.css';

interface AddressPageProps {
    className?: string
}

const fmtTxos = (count: number, sum: number) =>
    (count > 0 ? `${count} outputs` : 'No Outputs')
    + (sum > 0 ? ` (${formatSat(sum)})` : '');

const AddressPage = (props: AddressPageProps) => {
    const { className } = props;
    const { id } = useParams<{ id: string }>();
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
        return <div className={classNames(cls.AddressPage, 'container', className)}>Loading...</div>
    }

    if (!address) {
        return <div className={classNames(cls.AddressPage, 'container', className)}>Not found Address</div>
    }

    return (
        <div className={classNames(cls.AddressPage, 'container', className)}>
            <HStack gap='sm' justify='space-between'>
                <VStack gap='sm'>
                    <h1 className={cls.title}>Address</h1>
                    <Clipboard className={cls.clipboard} text={id as string}/>
                </VStack>
                <QrCode value={id as string} />
            </HStack>

            <VStack className={cls.statsTable}>
                {address.chain_stats.tx_count > 0 && (
                    <HStack justify='space-between' className={cls.statsTableItem}>
                        <span>Confirmed tx count</span>
                        <span>{formatNumber(address.chain_stats.tx_count)}</span>
                    </HStack>
                )}

                {address.chain_stats.funded_txo_count > 0 && (
                    <HStack justify='space-between' className={cls.statsTableItem}>
                        <span>Confirmed received</span>
                        <span>{fmtTxos(address.chain_stats.funded_txo_count, address.chain_stats.funded_txo_sum)}</span>
                    </HStack>
                )}

                {address.chain_stats.spent_txo_count > 0 && (
                    <HStack justify='space-between' className={cls.statsTableItem}>
                        <span>Confirmed spent</span>
                        <span>{fmtTxos(address.chain_stats.spent_txo_count, address.chain_stats.spent_txo_sum)}</span>
                    </HStack>
                )}

                {address.chain_stats.tx_count > 0 && (
                    <HStack justify='space-between' className={cls.statsTableItem}>
                        <span>Confirmed unspent</span>
                        <span>{fmtTxos(chainUtxoCount, chainUtxoSum)}</span>
                    </HStack>
                )}
            </VStack>

            {address.tokens && Object.keys(address.tokens).length > 0 && (
                <VStack className={cls.statsTable}>
                    <h2>Tokens info</h2>
                    {Object.entries(address.tokens).map(([tokenId, amount]) => (
                        <TokenItem
                            tokenId={tokenId}
                            amount={amount as number}
                            key={tokenId}
                        />
                    ))}
                </VStack>
            )}

            {!transactionsIsLoading && <Transactions
                txs={transactionsByAddress}
                totalTxs={address.chain_stats.tx_count}
                isTitleVisible
                loadMore={handleLoadMore}
                highlightAddress={id}
            />}
        </div>
    )
}

export default AddressPage;
