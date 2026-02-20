import { useMemo } from 'react';
import { Tag } from 'antd';
import { ArrowUpOutlined, ArrowDownOutlined } from '@ant-design/icons';

import type { IPeer } from '@/entities/Peer';

import { formatBytes, formatUptime } from './formatters';

export function usePeersColumns() {

    return useMemo(() => [
        {
            title: 'Address',
            dataIndex: 'addr',
            key: 'addr',
            ellipsis: true,
        },
        {
            title: 'Network',
            dataIndex: 'network',
            key: 'network',
            width: 90,
            render: (network: string) => (
                <Tag>{network}</Tag>
            ),
        },
        {
            title: 'Direction',
            dataIndex: 'inbound',
            key: 'inbound',
            width: 110,
            render: (inbound: boolean) => inbound
                ? <Tag icon={<ArrowDownOutlined/>} color="blue">Inbound</Tag>
                : <Tag icon={<ArrowUpOutlined/>} color="green">Outbound</Tag>,
        },
        {
            title: 'Protocol',
            dataIndex: 'protocol',
            key: 'protocol',
            width: 120,
        },
        {
            title: 'Reputation',
            dataIndex: 'reputation',
            key: 'reputation',
            width: 110,
            render: (rep: number) => rep.toFixed(1),
            sorter: (a: IPeer, b: IPeer) => a.reputation - b.reputation,
            defaultSortOrder: 'descend' as const,
        },
        {
            title: 'Sent',
            dataIndex: 'bytessent',
            key: 'bytessent',
            width: 90,
            render: (v: number) => formatBytes(v),
        },
        {
            title: 'Received',
            dataIndex: 'bytesrecv',
            key: 'bytesrecv',
            width: 90,
            render: (v: number) => formatBytes(v),
        },
        {
            title: 'Uptime',
            dataIndex: 'createtime',
            key: 'createtime',
            width: 100,
            render: (v: number) => formatUptime(v),
        },
    ], []);
}
