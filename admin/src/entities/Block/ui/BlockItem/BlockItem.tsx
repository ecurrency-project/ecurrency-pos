import { memo } from "react";
import { Link } from "react-router-dom";
import { useTranslation } from 'react-i18next';

import { formatNumber, formatTime } from "@/shared/utils";

import type { IBlock } from '../../model/types/IBlock.ts';

import cls from './BlockItem.module.css'

interface BlockItemProps {
    className?: string;
    block: IBlock;
}

export const BlockItem = memo(function BlockItem(props: BlockItemProps) {
    const {
        className,
        block,
    } = props;
    const { t } = useTranslation();

    return (
        <div className={className}>
            <Link className={cls.blockRow} to={`/blocks/${block.id}`}>
                <div className={cls.blockSell} data-label={t('Height')}>{block.height}</div>
                <div className={cls.blockSell} data-label={t('Timestamp')}>{formatTime(block.timestamp, false)}</div>
                <div className={cls.blockSell} data-label={t('Transactions')}>{formatNumber(block.tx_count)}</div>
                <div className={cls.blockSell} data-label={`${t('Size')} (KB)`}>{formatNumber(block.size / 1000)}</div>
                <div className={cls.blockSell} data-label={`${t('Weight')} (KWU)`}>{formatNumber(block.weight / 1000)}</div>
            </Link>
        </div>
    );
});
