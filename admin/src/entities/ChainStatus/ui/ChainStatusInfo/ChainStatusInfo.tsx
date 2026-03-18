import { memo } from 'react';
import { Card, Statistic, Skeleton, Progress } from 'antd';
import {
    DatabaseOutlined,
    FieldTimeOutlined,
    InboxOutlined,
    LineChartOutlined,
    SafetyCertificateOutlined, SyncOutlined,
} from '@ant-design/icons';
import classNames from 'classnames';

import { pfmt } from '@/shared/lib/fmtbtc/fmtbtc';
import { CHAIN_STATUS_POLL_INTERVAL } from '@/shared/const/const.ts';

import { useGetChainStatusQuery } from '../../api/chainStatusApi';
import { useSyncProgress } from '../../lib/useSyncProgress';

import cls from './ChainStatusInfo.module.css';

interface ChainStatusInfoProps {
    className?: string;
}

export const ChainStatusInfo = memo(function ChainStatusInfo(props: ChainStatusInfoProps) {
    const { className } = props;
    const { data: status, isLoading, error } = useGetChainStatusQuery(undefined, {
        pollingInterval: CHAIN_STATUS_POLL_INTERVAL,
        refetchOnMountOrArgChange: true,
    });

    const syncProgress = useSyncProgress(status);

    if (isLoading) {
        return (
            <div className={classNames(cls.ChainStatusInfo, className)}>
                <Card className={cls.mainCard}>
                    <div className={cls.row}>
                        {[...Array(5)].map((_, i) => (
                            <div key={i} className={cls.col}>
                                <Skeleton active paragraph={{ rows: 1 }} title={false} />
                            </div>
                        ))}
                    </div>
                </Card>
            </div>
        );
    }

    if (error || !status) {
        return null;
    }

    const genesisDate = status.genesistime
        ? new Date(status.genesistime * 1000).toLocaleDateString()
        : '2018-01-01';

    return (
        <div className={classNames(cls.ChainStatusInfo, className)}>
            {syncProgress !== null && (
                <Card className={cls.mainCard}>
                    <div className={cls.syncRow}>
                        <SyncOutlined spin className={cls.syncIcon} />
                        <div className={cls.syncContent}>
                            <span className={cls.syncLabel}>Sync Progress</span>
                            <Progress
                                percent={Number(syncProgress.toFixed(2))}
                                status="active"
                            />
                        </div>
                    </div>
                </Card>
            )}

            <Card className={cls.mainCard}>
                <div className={cls.row}>
                    <div className={cls.col}>
                        <Statistic
                            title={(
                                <span className={cls.title}>
                                    <DatabaseOutlined className={cls.icon} />
                                    Total Coins
                                </span>
                            )}
                            value={pfmt(status.total_coins, 'sat', 'btc')}
                            valueStyle={{ color: '#faad14' }}
                        />
                    </div>
                    <div className={cls.col}>
                        <Statistic
                            title={(
                                <span className={cls.title}>
                                    <SafetyCertificateOutlined className={cls.icon} />
                                    Confirmation Weight
                                </span>
                            )}
                            value={status.weight}
                            formatter={(value) => value.toLocaleString()}
                            valueStyle={{ color: '#1890ff' }}
                        />
                    </div>
                    <div className={cls.col}>
                        <Statistic
                            title={(
                                <span className={cls.title}>
                                    <InboxOutlined className={cls.icon} />
                                    Mempool Size
                                </span>
                            )}
                            value={status.mempool_size}
                            suffix={<span className={cls.suffix}>txs</span>}
                            valueStyle={{ color: '#52c41a' }}
                        />
                    </div>
                    <div className={cls.col}>
                        <Statistic
                            title={(
                                <span className={cls.title}>
                                    <LineChartOutlined className={cls.icon} />
                                    Block Reward
                                </span>
                            )}
                            value={pfmt(status.reward, 'sat', 'btc')}
                            valueStyle={{ color: '#eb2f96' }}
                        />
                    </div>
                    <div className={cls.col}>
                        <Statistic
                            title={(
                                <span className={cls.title}>
                                    <FieldTimeOutlined className={cls.icon} />
                                    Genesis Time
                                </span>
                            )}
                            value={genesisDate}
                            valueStyle={{ color: '#722ed1' }}
                        />
                    </div>
                </div>
            </Card>
        </div>
    );
});
