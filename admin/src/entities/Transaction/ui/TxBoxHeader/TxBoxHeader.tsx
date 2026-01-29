import { memo, useState } from 'react';
import { Link } from 'react-router-dom';
import classNames from 'classnames';
import { useTranslation } from 'react-i18next';
import { Tooltip } from 'antd';

import { HStack, VStack } from '@/shared/ui/Stack';
import { Button } from '@/shared/ui/Button';
import { formatSat, formatTime } from '@/shared/utils';

import ExpandMoreIcon from "@/shared/assets/icons/expand_more.svg?react";

import cls from './TxBoxHeader.module.css';

interface TxBoxHeaderProps {
    className?: string
    txid: string
    toggleExpanded: () => void
    expanded: boolean;
    date?: number
    fee: number
}

export const TxBoxHeader = memo(function TxBoxHeader(props: TxBoxHeaderProps) {
    const {
        className,
        txid,
        toggleExpanded,
        expanded,
        date,
        fee,
    } = props;
    const { t } = useTranslation();
    const [useUTC, setUseUTC] = useState(false);

    return (
        <HStack className={classNames(cls.TxBoxHeader, className)} justify="space-between">
            <VStack maxWidth>
                <Link to={`/tx/${txid}`} className={cls.link}>{txid}</Link>
                <span className={cls.commission}>{t('_commission_fee', { fee: formatSat(fee) })}</span>
                {date && <Tooltip title={t(useUTC ? '_click_show_local_time' : '_click_show_utc_time')} placement="top">
                    <span className={cls.time} onClick={() => setUseUTC(!useUTC)} style={{cursor: 'pointer'}}>{formatTime(date, useUTC)}</span>
                </Tooltip>}
            </VStack>
            <Button
                className={cls.detailsBtn}
                onClick={toggleExpanded}
                icon={<ExpandMoreIcon fill={'var(--yellow)'} className={expanded ? cls.expended : ''}/>}
                iconPlacement='end'
            >
                <span>{t('_details')}</span>
            </Button>
        </HStack>
    );
});
