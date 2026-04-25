import { memo } from 'react';
import { Card, Tag } from 'antd';
import { ArrowUpOutlined, ArrowDownOutlined } from '@ant-design/icons';

import type { IPeer } from '@/entities/Peer';

import { formatBytes, formatUptime } from '../lib/formatters';

import cls from './Peers.module.css';

interface PeerMobileCardProps {
    peer: IPeer;
}

export const PeerMobileCard = memo(function PeerMobileCard({ peer }: PeerMobileCardProps) {

    return (
        <Card size="small" className={cls.mobileCard}>
            <div className={cls.mobileRow}>
                <span className={cls.mobileLabel}>Address</span>
                <span className={cls.mobileValue}>{peer.addr}</span>
            </div>
            <div className={cls.mobileRow}>
                <span className={cls.mobileLabel}>Network</span>
                <span className={cls.mobileValue}>
                    <Tag>{peer.network}</Tag>
                </span>
            </div>
            <div className={cls.mobileRow}>
                <span className={cls.mobileLabel}>Direction</span>
                <span className={cls.mobileValue}>
                    {peer.inbound
                        ? <Tag icon={<ArrowDownOutlined/>} color="blue">Inbound</Tag>
                        : <Tag icon={<ArrowUpOutlined/>} color="green">Outbound</Tag>
                    }
                </span>
            </div>
            <div className={cls.mobileRow}>
                <span className={cls.mobileLabel}>Protocol</span>
                <span className={cls.mobileValue}>{peer.protocol}</span>
            </div>
            <div className={cls.mobileRow}>
                <span className={cls.mobileLabel}>Reputation</span>
                <span className={cls.mobileValue}>{peer.reputation.toFixed(1)}</span>
            </div>
            <div className={cls.mobileRow}>
                <span className={cls.mobileLabel}>Sent / Recv</span>
                <span className={cls.mobileValue}>
                    {formatBytes(peer.bytessent)} / {formatBytes(peer.bytesrecv)}
                </span>
            </div>
            <div className={cls.mobileRow}>
                <span className={cls.mobileLabel}>Uptime</span>
                <span className={cls.mobileValue}>{formatUptime(peer.createtime)}</span>
            </div>
        </Card>
    );
});
