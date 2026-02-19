import { memo } from 'react';
import { useTranslation } from 'react-i18next';
import { Link } from 'react-router-dom';
import { Card, Switch } from 'antd';

import { RouterPath } from '@/shared/config/router/router';

import type { IMyAddress } from '../model/types/myAddress';

import cls from './MyAddressMobileCard.module.css';

interface MyAddressMobileCardProps {
    address: IMyAddress;
    loading: boolean;
    onStakedChange: (address: string, staked: boolean) => void;
}

export const MyAddressMobileCard = memo(function MyAddressMobileCard(props: MyAddressMobileCardProps) {
    const { address, loading, onStakedChange } = props;
    const { t } = useTranslation();

    return (
        <Card size="small" className={cls.mobileCard}>
            <div className={cls.mobileRow}>
                <span className={cls.mobileLabel}>{t('Address')}</span>
                <span className={cls.mobileValue}>
                    <Link to={RouterPath.address.replace(':id', address.address)}>
                        {address.address}
                    </Link>
                </span>
            </div>
            <div className={cls.mobileRow}>
                <span className={cls.mobileLabel}>{t('Staked')}</span>
                <span className={cls.mobileValue}>
                    <Switch
                        checked={!!address.staked}
                        onChange={(checked) => onStakedChange(address.address, checked)}
                        loading={loading}
                    />
                </span>
            </div>
        </Card>
    );
});
