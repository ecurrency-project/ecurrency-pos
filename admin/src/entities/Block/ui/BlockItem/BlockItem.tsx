import { memo } from "react";
import { Link } from "react-router-dom";

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

    return (
        <div className={className}>
            <Link className={cls.blockRow} to={`/blocks/${block.id}`}>
                <div className={cls.blockSell} data-label='Height'>{block.height}</div>
                <div className={cls.blockSell} data-label='Timestamp'>{formatTime(block.timestamp, false)}</div>
                <div className={cls.blockSell} data-label='Transactions'>{formatNumber(block.tx_count)}</div>
                <div className={cls.blockSell} data-label='Size (KB)'>{formatNumber(block.size / 1000)}</div>
                <div className={cls.blockSell} data-label='Weight (KWU)'>{formatNumber(block.weight / 1000)}</div>
            </Link>
        </div>
    );
});
