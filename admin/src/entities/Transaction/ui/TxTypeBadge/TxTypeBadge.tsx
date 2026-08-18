import { Tag } from 'antd';
import type { TagProps } from 'antd';
import classNames from 'classnames';

import { isNonStandardType, txTypeLabel } from '../../lib/txType';

import cls from './TxTypeBadge.module.css';

const COLORS: Record<string, TagProps['color']> = {
    coinbase: 'blue',
    stake: 'cyan',
    tokens: 'purple',
    slashing: 'error',
    burn: 'warning',
    downgrade: 'gold',
    upgrade_stop: 'default',
};

interface TxTypeBadgeProps {
    className?: string;
    type?: string;
}

export const TxTypeBadge = ({ className, type }: TxTypeBadgeProps) => {
    if (!isNonStandardType(type)) return null;

    return (
        <Tag
            className={classNames(cls.badge, className)}
            color={COLORS[type as string]}
            translate="no"
            variant="filled"
        >
            {txTypeLabel(type)}
        </Tag>
    );
};
