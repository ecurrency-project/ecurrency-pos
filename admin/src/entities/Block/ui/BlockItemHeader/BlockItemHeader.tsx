import {memo} from "react";
import classNames from "classnames";

import cls from './BlockItemHeader.module.css'

interface BlockItemHeaderProps {
    className?: string;
}

export const BlockItemHeader = memo(function BlockItemHeader(props: BlockItemHeaderProps) {
    const {
        className
    } = props;

    return (
        <div className={classNames(cls.BlockItemHeader, className)}>
            <div className={cls.blockSell} data-label="Height">Height</div>
            <div className={cls.blockSell} data-label="Timestamp">Timestamp</div>
            <div className={cls.blockSell} data-label="Transactions">Transactions</div>
            <div className={cls.blockSell} data-label="Size (KB)">Size (KB)</div>
            <div className={cls.blockSell} data-label="Weight (KWU)">Weight (KWU)</div>
        </div>
    );
});
