import classNames from 'classnames';

import { NATIVE_PRECISION } from '@/entities/Transaction/ui/utils';

import { HStack } from '@/shared/ui/Stack';
import { formatNumber } from '@/shared/utils';
import { sat2btc } from '@/shared/lib/fmtbtc';
import { brand } from '@/brand';

import cls from './TxCoinbase.module.css';

interface TxCoinbaseProps {
    className?: string;
    value: number;
    index?: number;
}

export const TxCoinbase = (props: TxCoinbaseProps) => {
    const { className, value, index } = props;

    return (
        <div className={classNames(cls.TxCoinbase, className)}>
            <div className={cls.header}>
                <HStack align="start">
                    <span className={cls.index}>{`#${index}`}</span>
                    <div className={cls.wrapper}>
                        Coinbase
                        <span className={cls.amount}>{formatNumber(sat2btc(value), NATIVE_PRECISION)}{' '}{brand.assetLabel}</span>
                    </div>
                </HStack>
            </div>
        </div>
    )
}
