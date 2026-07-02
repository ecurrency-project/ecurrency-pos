import { Skeleton, Switch, Typography, message } from 'antd';
import classNames from 'classnames';

import { useGetChainStatusQuery } from '@/entities/ChainStatus';

import cls from './StakingToggle.module.css';

import { useSetGenerateMutation } from '../../api/stakingToggleApi';

const { Text } = Typography;

interface StakingToggleProps {
    className?: string;
}

const getErrorText = (e: unknown): string => {
    if (typeof e === 'object' && e !== null && 'data' in e) {
        const data = (e as { data?: unknown }).data;
        if (typeof data === 'string' && data.trim() !== '') {
            return data.trim();
        }
    }
    return 'Failed to change staking state';
};

export const StakingToggle = (props: StakingToggleProps) => {
    const { className } = props;

    const { data: status, isLoading: isStatusLoading } = useGetChainStatusQuery();
    const [setGenerate, { isLoading: isToggling }] = useSetGenerateMutation();

    const wallet = status?.wallet;

    const onChange = async (checked: boolean) => {
        try {
            await setGenerate({ generate: checked }).unwrap();
            message.success(checked ? 'Staking enabled' : 'Staking disabled');
        } catch (e) {
            message.error(getErrorText(e));
        }
    };

    if (isStatusLoading) {
        return <Skeleton active paragraph={{ rows: 1 }} />;
    }

    return (
        <div className={classNames(cls.StakingToggle, className)}>
            <div className={cls.control}>
                <Switch
                    checked={wallet?.generate === true}
                    onChange={onChange}
                    loading={isToggling}
                    disabled={!wallet}
                />
                <span className={cls.label}>Staking</span>
            </div>

            {wallet?.locked && (
                <Text type="secondary" className={cls.hint}>
                    The wallet is locked. Enabling staking will unlock it with the admin password.
                </Text>
            )}
        </div>
    );
};
