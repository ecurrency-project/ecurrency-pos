import type { CSSProperties } from 'react';
import { useNavigate } from 'react-router-dom';
import { Dropdown, type MenuProps } from 'antd';
import classNames from 'classnames';

import ExternalLinkIcon from '@/shared/assets/icons/external_link.svg?react';
import MoreDotsIcon from '@/shared/assets/icons/more_dots.svg?react';
import SendArrowIcon from '@/shared/assets/icons/send_arrow.svg?react';

import { useGetTokenInfoQuery } from '../../api/tokenApi.ts';
import { tokenLabels } from '../../lib/tokenLabels.ts';
import { formatTokenAmount } from '../../lib/formatTokenAmount.ts';
import { tokenHue } from '../../lib/tokenHue.ts';

import cls from './TokenChip.module.css';

interface TokenChipProps {
    tokenId: string;
    amount: number | string;
    variant?: 'chip' | 'row';
    onSendToken?: (tokenId: string) => void;
    className?: string;
}

export const TokenChip = ({ tokenId, amount, variant = 'chip', onSendToken, className }: TokenChipProps) => {
    const navigate = useNavigate();
    const { data } = useGetTokenInfoQuery({ tokenId });

    const { ticker, name } = tokenLabels(data);
    const label = ticker || `${tokenId.slice(0, 4)}…`;
    const monogram = (label[0] || '?').toUpperCase();
    const monogramStyle = { '--chip-h': tokenHue(ticker || tokenId) } as CSSProperties;
    const balance = formatTokenAmount(amount, data?.decimals ?? 0);

    const items: MenuProps['items'] = [
        ...(onSendToken
            ? [{
                key: 'send-token',
                label: `Send ${label}`,
                icon: <SendArrowIcon className={cls.menuIcon} />,
                onClick: () => onSendToken(tokenId),
            }]
            : []),
        {
            key: 'token-page',
            label: 'Open token page',
            icon: <ExternalLinkIcon className={cls.menuIcon} />,
            onClick: () => navigate(`/token/${tokenId}`),
        },
    ];

    return (
        <Dropdown
            menu={{ items }}
            trigger={['click']}
            popupRender={(menu) => (
                <div className={cls.menuWrap}>
                    <div className={cls.menuHeader}>
                        <span className={cls.menuMono} style={monogramStyle} aria-hidden="true">
                            {monogram}
                        </span>
                        <span className={cls.menuMeta}>
                            <span className={cls.menuTicker}>{label}</span>
                            {name && <span className={cls.menuName}>{name}</span>}
                        </span>
                    </div>
                    {menu}
                </div>
            )}
        >
            {variant === 'chip' ? (
                <button type="button" className={classNames(cls.TokenChip, className)}>
                    <span className={cls.mono} style={monogramStyle} aria-hidden="true">
                        {monogram}
                    </span>
                    <span className={cls.ticker}>{label}</span>
                    <span className={cls.amount} translate="no">{balance}</span>
                </button>
            ) : (
                <button type="button" className={classNames(cls.TokenRow, className)}>
                    <span className={cls.rowMono} style={monogramStyle} aria-hidden="true">
                        {monogram}
                    </span>
                    <span className={cls.rowMeta}>
                        <span className={cls.rowTicker}>{label}</span>
                        {name && <span className={cls.rowName}>{name}</span>}
                    </span>
                    <span className={cls.rowAmount} translate="no">{balance}</span>
                    <MoreDotsIcon className={cls.rowMore} aria-hidden="true" />
                </button>
            )}
        </Dropdown>
    );
};
