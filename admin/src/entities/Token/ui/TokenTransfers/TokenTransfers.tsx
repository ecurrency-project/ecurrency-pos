import { useCallback, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';

import { Button } from '@/shared/ui/Button';

import { useGetTokenTransfersByAddressQuery, useLazyGetTokenTransfersByAddressQuery } from '../../api/tokenApi.ts';
import { formatTokenAmount } from '../../lib/formatTokenAmount.ts';
import type { TokenTransfer } from '../../model/types/token.ts';

import cls from './TokenTransfers.module.css';

interface TokenTransfersProps {
    address: string;
    tokenId: string;
    decimals: number;
    ticker: string;
}

const PAGE_SIZE = 25;

export const TokenTransfers = ({ address, tokenId, decimals, ticker }: TokenTransfersProps) => {
    const { data: firstPage, isFetching: isLoadingFirst, isError } = useGetTokenTransfersByAddressQuery({ address, tokenId });
    const [extraItems, setExtraItems] = useState<TokenTransfer[]>([]);
    const [exhausted, setExhausted] = useState(false);
    const [trigger, { isFetching: isLoadingMore }] = useLazyGetTokenTransfersByAddressQuery();

    const items = useMemo(() => [...(firstPage ?? []), ...extraItems], [firstPage, extraItems]);
    const lastBatchLength = extraItems.length > 0 ? extraItems.length % PAGE_SIZE || PAGE_SIZE : firstPage?.length ?? 0;
    const hasMore = !isError && !exhausted && items.length > 0 && lastBatchLength >= PAGE_SIZE;

    const handleLoadMore = useCallback(() => {
        if (!items.length) return;
        const lastSeen = items[items.length - 1][0];
        trigger({ address, tokenId, lastSeen }).unwrap()
            .then((res) => {
                setExtraItems((prev) => [...prev, ...res]);
                if (res.length < PAGE_SIZE) setExhausted(true);
            })
            .catch(() => setExhausted(true));
    }, [items, trigger, address, tokenId]);

    if (items.length === 0) {
        return (
            <div className={cls.empty}>
                {isLoadingFirst ? 'Loading...' : 'No transfers'}
            </div>
        );
    }

    return (
        <div className={cls.TokenTransfers}>
            <div className={cls.head}>
                <span>Transfer</span>
                <span>Amount</span>
            </div>
            {items.map(([txid, amount, height]) => {
                const positive = amount >= 0;
                return (
                    <div className={cls.row} key={`${txid}_${height}`}>
                        <div className={cls.left}>
                            <Link to={`/tx/${txid}`} className={cls.txid}>{txid.slice(0, 10)}…</Link>
                            <span className={cls.block}>{`Block ${formatTokenAmount(height, 0)}`}</span>
                        </div>
                        <span className={positive ? cls.in : cls.out} translate="no">
                            {positive ? '+' : '-'}{formatTokenAmount(Math.abs(amount), decimals)}{ticker ? ` ${ticker}` : ''}
                        </span>
                    </div>
                );
            })}
            {hasMore && (
                <div className={cls.more}>
                    <Button onClick={handleLoadMore} disabled={isLoadingMore}>Load more</Button>
                </div>
            )}
        </div>
    );
};
