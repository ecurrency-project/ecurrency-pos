import { useParams, Link } from 'react-router-dom';
import classNames from 'classnames';

import { useGetTokenInfoQuery, tokenLabels } from '@/entities/Token';

import { Clipboard } from '@/shared/ui/Clipboard';
import { HStack, VStack } from '@/shared/ui/Stack';
import { formatTime } from '@/shared/utils';

import CubeIcon from '@/shared/assets/icons/cube.svg?react';

import cls from './TokenDetailsPage.module.css';

interface TokenDetailsPageProps {
    className?: string;
}

const TokenDetailsPage = ({ className }: TokenDetailsPageProps) => {
    const { id } = useParams<{ id: string }>();
    const { data: token, isLoading } = useGetTokenInfoQuery({ tokenId: id as string });

    if (isLoading) {
        return <div className={classNames(cls.TokenDetailsPage, 'container', className)}>Loading...</div>;
    }

    if (!token) {
        return <div className={classNames(cls.TokenDetailsPage, 'container', className)}>Token not found</div>;
    }

    const { ticker, name } = tokenLabels(token);

    return (
        <div className={classNames(cls.TokenDetailsPage, 'container', className)}>
            <VStack gap="sm">
                <HStack>
                    <CubeIcon fill="#ffbb00" width="50px" height="50px" />
                    <h1 className={cls.title}>{`Token${ticker ? ` ${ticker}` : ''}`}</h1>
                </HStack>
                <Clipboard text={id as string} />
            </VStack>

            <VStack justify="space-between" className={cls.statsTable}>
                {ticker && (
                    <HStack justify="space-between" className={cls.statsTableItem}>
                        <span>Symbol</span>
                        <span translate="no">{ticker}</span>
                    </HStack>
                )}
                {name && (
                    <HStack justify="space-between" className={cls.statsTableItem}>
                        <span>Name</span>
                        <span translate="no">{name}</span>
                    </HStack>
                )}
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Decimals</span>
                    <span>{token.decimals}</span>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Issuer</span>
                    <Link to={`/address/${token.issuer}`} className="mono">{token.issuer}</Link>
                </HStack>
                {token.create_time ? (
                    <HStack justify="space-between" className={cls.statsTableItem}>
                        <span>Created</span>
                        <span>{formatTime(token.create_time)}</span>
                    </HStack>
                ) : null}
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Creation transaction</span>
                    <Link to={`/tx/${token.token_id}`} className="mono">{token.token_id}</Link>
                </HStack>
            </VStack>
        </div>
    );
};

export default TokenDetailsPage;
