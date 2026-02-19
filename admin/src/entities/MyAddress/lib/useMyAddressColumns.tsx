import { useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import { Link } from 'react-router-dom';
import { Switch } from 'antd';
import type { ColumnsType } from 'antd/es/table';

import { RouterPath } from '@/shared/config/router/router';

import type { IMyAddress } from '../model/types/myAddress';

interface UseMyAddressColumnsProps {
    editingAddresses: Set<string>;
    onStakedChange: (address: string, staked: boolean) => void;
}

export function useMyAddressColumns(props: UseMyAddressColumnsProps) {
    const { editingAddresses, onStakedChange } = props;
    const { t } = useTranslation();

    return useMemo((): ColumnsType<IMyAddress> => [
        {
            title: t('Address'),
            dataIndex: 'address',
            key: 'address',
            render: (addr: string) => (
                <Link to={RouterPath.address.replace(':id', addr)}>{addr}</Link>
            ),
        },
        {
            title: t('Staked'),
            dataIndex: 'staked',
            key: 'staked',
            width: 120,
            align: 'center',
            render: (staked: number, record: IMyAddress) => (
                <Switch
                    checked={!!staked}
                    onChange={(checked) => onStakedChange(record.address, checked)}
                    loading={editingAddresses.has(record.address)}
                />
            ),
        },
    ], [t, editingAddresses, onStakedChange]);
}
