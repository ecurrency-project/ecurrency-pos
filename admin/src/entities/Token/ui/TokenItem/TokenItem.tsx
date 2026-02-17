import { Link } from 'react-router-dom';

import { HStack } from '@/shared/ui/Stack';
import { moveDecimalPoint } from '@/shared/lib/moveDecimalPoint/moveDecimalPoint';

import { useGetTokenInfoQuery } from '../../api/tokenApi.ts';

import cls from './TokenItem.module.scss';

interface TokenItemProps {
    tokenId: string;
    amount: number;
}

export const TokenItem = ({ tokenId, amount }: TokenItemProps) => {
    const { data, isLoading } = useGetTokenInfoQuery({ tokenId });

    if (isLoading) {
        return (
            <HStack justify="space-between" className={cls.TokenItem}>
                <Link to={`/tx/${tokenId}`} className='mono'>{tokenId.slice(0, 8)}...</Link>
                <span>...</span>
            </HStack>
        )
    }

    if (!data) {
        return null;
    }

    const tokenAmount = moveDecimalPoint(amount, -data.decimals);

    return (
        <HStack justify="space-between" className={cls.TokenItem}>
            <Link to={`/tx/${tokenId}`} className='mono'>{data.token_id}</Link>
            <span>{tokenAmount} {data.symbol} {data.name ? `(${data.name})` : ''}</span>
        </HStack>
    );
}
