import { useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import { Tag } from 'antd';
import { ArrowUpOutlined, ArrowDownOutlined } from '@ant-design/icons';

import type { IPeer } from '@/entities/Peer';

import { formatBytes, formatUptime } from './formatters';

export function usePeersColumns() {
    const { t } = useTranslation();

    return useMemo(() => [
        {
            title: t('Address'),
            dataIndex: 'addr',
            key: 'addr',
            ellipsis: true,
        },
        {
            title: t('Network'),
            dataIndex: 'network',
            key: 'network',
            width: 90,
            render: (network: string) => (
                <Tag>{network}</Tag>
            ),
        },
        {
            title: t('Direction'),
            dataIndex: 'inbound',
            key: 'inbound',
            width: 110,
            render: (inbound: boolean) => inbound
                ? <Tag icon={<ArrowDownOutlined/>} color="blue">{t('Inbound')}</Tag>
                : <Tag icon={<ArrowUpOutlined/>} color="green">{t('Outbound')}</Tag>,
        },
        {
            title: t('Protocol'),
            dataIndex: 'protocol',
            key: 'protocol',
            width: 120,
        },
        {
            title: t('Reputation'),
            dataIndex: 'reputation',
            key: 'reputation',
            width: 110,
            render: (rep: number) => rep.toFixed(1),
            sorter: (a: IPeer, b: IPeer) => a.reputation - b.reputation,
            defaultSortOrder: 'descend' as const,
        },
        {
            title: t('Sent'),
            dataIndex: 'bytessent',
            key: 'bytessent',
            width: 90,
            render: (v: number) => formatBytes(v),
        },
        {
            title: t('Received'),
            dataIndex: 'bytesrecv',
            key: 'bytesrecv',
            width: 90,
            render: (v: number) => formatBytes(v),
        },
        {
            title: t('Uptime'),
            dataIndex: 'createtime',
            key: 'createtime',
            width: 100,
            render: (v: number) => formatUptime(v),
        },
    ], [t]);
}
