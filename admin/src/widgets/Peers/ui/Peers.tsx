import { memo } from 'react';
import { Card, Table, Skeleton } from 'antd';
import { TeamOutlined } from '@ant-design/icons';
import classNames from 'classnames';

import { useGetPeersQuery } from '@/entities/Peer';

import { usePeersColumns } from '../lib/usePeersColumns';
import { PeerMobileCard } from './PeerMobileCard';

import cls from './Peers.module.css';

interface PeersProps {
    className?: string;
}

export const Peers = memo(function Peers(props: PeersProps) {
    const { className } = props;
    const { data: peers, isLoading } = useGetPeersQuery(undefined, {
        pollingInterval: 10000,
    });

    const columns = usePeersColumns();

    const header = (
        <div className={cls.header}>
            <TeamOutlined/>
            <span className={cls.headerTitle}>Peers</span>
            {peers && peers.length > 0 && (
                <span className={cls.peerCount}>({peers.length})</span>
            )}
        </div>
    );

    if (isLoading) {
        return (
            <div className={classNames(cls.Peers, className)}>
                <Card className={cls.peersCard}>
                    {header}
                    <Skeleton active paragraph={{ rows: 4 }}/>
                </Card>
            </div>
        );
    }

    if (!peers || peers.length === 0) {
        return (
            <div className={classNames(cls.Peers, className)}>
                <Card className={cls.peersCard}>
                    {header}
                    <span>No peers connected</span>
                </Card>
            </div>
        );
    }

    return (
        <div className={classNames(cls.Peers, className)}>
            <Card className={cls.peersCard}>
                {header}

                <div className={cls.desktopTable}>
                    <Table
                        dataSource={peers}
                        columns={columns}
                        rowKey="addr"
                        size="small"
                        pagination={false}
                    />
                </div>

                <div className={cls.mobileList}>
                    {peers.map((peer) => (
                        <PeerMobileCard key={peer.addr} peer={peer} />
                    ))}
                </div>
            </Card>
        </div>
    );
});
