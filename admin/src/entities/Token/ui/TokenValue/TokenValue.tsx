import { Link } from 'react-router-dom';

import { useGetTokenInfoQuery } from '../../api/tokenApi.ts';
import { tokenLabels } from '../../lib/tokenLabels.ts';
import { formatTokenAmount } from '../../lib/formatTokenAmount.ts';

interface TokenValueProps {
    tokenId: string;
    amount: number | string;
    decimals?: number;
    link?: boolean;
    className?: string;
}

export const TokenValue = ({ tokenId, amount, decimals, link = false, className }: TokenValueProps) => {
    const { data } = useGetTokenInfoQuery({ tokenId });

    const effectiveDecimals = data?.decimals ?? decimals ?? 0;
    const formatted = formatTokenAmount(amount, effectiveDecimals);
    const { ticker } = tokenLabels(data);
    const label = ticker || `${tokenId.slice(0, 4)}…`;

    return (
        <span className={className} translate="no" style={{ textTransform: 'none' }}>
            {formatted}{' '}
            {link ? <Link to={`/token/${tokenId}`}>{label}</Link> : label}
        </span>
    );
};
