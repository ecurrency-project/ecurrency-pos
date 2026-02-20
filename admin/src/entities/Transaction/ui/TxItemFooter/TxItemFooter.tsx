import { memo } from 'react';
import { useSelector } from 'react-redux';
import classNames from 'classnames';

import { getTipHeight } from '@/entities/TipHeight';

import { HStack } from '@/shared/ui/Stack';
import { formatSat } from '@/shared/utils';

import { isAllNative, isAllUnconfidential, isRbf, outTotal } from './../utils.tsx';
import type { ITxStatus, Vin, Vout } from '../../model/types/ITransaction.ts';

import cls from './TxItemFooter.module.css';

interface TransactionBoxProps {
    className?: string
    txStatus?: ITxStatus;
    tipHeight?: number;
    vin: Vin[];
    vout: Vout[];
}

export const TxItemFooter = memo(function TxItemFooter(props: TransactionBoxProps) {
    const {
        className,
        txStatus,
        vin,
        vout,
    } = props;

    const tipHeight = useSelector(getTipHeight);

    const confirmationText = !txStatus?.confirmed ? 'Unconfirmed' : tipHeight ? `${tipHeight - txStatus.block_height + 1} confirmations` : 'Confirmed';

    return (
        <HStack
            className={classNames(cls.TxItemFooter, className)}
            justify="end"
            gap={'md'}
        >
            {txStatus && (
                <span>{confirmationText} {!txStatus.confirmed && isRbf(vin) ? '(RBF)' : ''}</span>
            )}
            <span>
                {!isAllUnconfidential(vout) ? 'Confidential' : isAllNative(vout) ? formatSat(outTotal(vout)) : ''}
            </span>
        </HStack>
    );
});
