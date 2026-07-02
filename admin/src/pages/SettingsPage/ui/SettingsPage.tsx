import { Card } from 'antd';
import classNames from 'classnames';

import { StakingToggle } from '@/features/StakingToggle';
import { WalletPasswordForm } from '@/features/WalletPassword';

import cls from './SettingsPage.module.css';

interface SettingsPageProps {
    className?: string;
}

const SettingsPage = ({ className }: SettingsPageProps) => {
    return (
        <div className={classNames(cls.SettingsPage, 'container', className)}>
            <h1 className={cls.title}>Settings</h1>

            <Card title="Staking" className={cls.card}>
                <StakingToggle />
            </Card>

            <Card title="Wallet password" className={cls.card}>
                <WalletPasswordForm />
            </Card>
        </div>
    );
};

export default SettingsPage;
