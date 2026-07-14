import { useState } from 'react';
import { Link } from 'react-router-dom';
import classNames from 'classnames';

import ExpandMoreIcon from '@/shared/assets/icons/expand_more.svg?react';

import { useGetTokenInfoQuery } from '../../api/tokenApi.ts';
import { tokenLabels } from '../../lib/tokenLabels.ts';
import { formatTokenAmount } from '../../lib/formatTokenAmount.ts';
import { TokenTransfers } from '../TokenTransfers/TokenTransfers.tsx';

import cls from './TokenItem.module.css';

interface TokenItemProps {
    tokenId: string;
    amount: number;
    address?: string;
}

const shortHash = (id: string) => `${id.slice(0, 8)}…${id.slice(-8)}`;

export const TokenItem = ({ tokenId, amount, address }: TokenItemProps) => {
    const { data, isLoading } = useGetTokenInfoQuery({ tokenId });
    const [expanded, setExpanded] = useState(false);

    if (isLoading) {
        return (
            <div className={cls.TokenItem}>
                <div className={cls.row}>
                    <span className={cls.hash}>{tokenId.slice(0, 8)}…</span>
                    <span>…</span>
                </div>
            </div>
        );
    }

    if (!data) {
        return null;
    }

    const { ticker, name } = tokenLabels(data);
    const title = ticker || shortHash(tokenId);
    const subtitle = name || (ticker ? shortHash(tokenId) : 'no symbol');
    const balance = formatTokenAmount(amount, data.decimals);

    return (
        <div className={cls.TokenItem}>
            <div className={cls.row}>
                <div className={cls.meta}>
                    <Link to={`/token/${tokenId}`} className={ticker ? cls.ticker : cls.hash}>{title}</Link>
                    <span className={cls.sub}>{subtitle}</span>
                </div>
                <div className={cls.right}>
                    <span className={cls.balance} translate="no">
                        {balance}{ticker ? <span className={cls.unit}> {ticker}</span> : ''}
                    </span>
                    {address && (
                        <button
                            type="button"
                            className={cls.toggle}
                            aria-label="Transfers"
                            aria-expanded={expanded}
                            onClick={() => setExpanded((v) => !v)}
                        >
                            <ExpandMoreIcon className={classNames(cls.chev, { [cls.chevOpen]: expanded })} />
                        </button>
                    )}
                </div>
            </div>
            {address && expanded && (
                <TokenTransfers address={address} tokenId={tokenId} decimals={data.decimals} ticker={ticker} />
            )}
        </div>
    );
};
