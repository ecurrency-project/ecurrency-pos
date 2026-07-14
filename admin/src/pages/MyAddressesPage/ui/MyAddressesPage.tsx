import { useCallback, useState } from 'react';
import { Link } from 'react-router-dom';
import { Skeleton, message } from 'antd';
import { WalletOutlined, SendOutlined } from '@ant-design/icons';
import classNames from 'classnames';

import {
    useGetMyAddressesQuery,
    useEditAddressStakedMutation,
} from '@/entities/MyAddress';
import { GenerateAddressButton } from '@/features/GenerateAddress';
import { ImportAddressButton } from '@/features/ImportAddress';
import { WalletCards } from '@/widgets/WalletCards';
import { Button } from '@/shared/ui/Button';
import { RouterPath, RoutersApp } from '@/shared/config/router/router';

import cls from './MyAddressesPage.module.css';

const MyAddressesPage = () => {
    const { data: addresses, isLoading } = useGetMyAddressesQuery(undefined, {
        pollingInterval: 10000,
    });

    const [editStaked] = useEditAddressStakedMutation();
    const [editingAddresses, setEditingAddresses] = useState<Set<string>>(new Set());

    const handleStakedChange = useCallback(async (address: string, staked: boolean) => {
        setEditingAddresses((prev) => new Set(prev).add(address));
        try {
            await editStaked({ address, staked: staked ? 1 : 0 }).unwrap();
            message.success('Staked status updated');
        } catch {
            message.error('Failed to update staked status');
        } finally {
            setEditingAddresses((prev) => {
                const next = new Set(prev);
                next.delete(address);
                return next;
            });
        }
    }, [editStaked]);

    const header = (
        <div className={cls.header}>
            <div className={cls.headerLeft}>
                <WalletOutlined/>
                <span className={cls.headerTitle}>My Addresses</span>
                {addresses && addresses.length > 0 && (
                    <span className={cls.addressCount}>({addresses.length})</span>
                )}
            </div>
            <div className={cls.headerActions}>
                <Link to={RouterPath[RoutersApp.SEND_TRANSACTION]}>
                    <Button type="primary" icon={<SendOutlined />}>Send</Button>
                </Link>
                <GenerateAddressButton/>
                <ImportAddressButton/>
            </div>
        </div>
    );

    return (
        <div className={classNames(cls.MyAddressesPage, 'container')}>
            {header}

            {isLoading ? (
                <Skeleton active paragraph={{ rows: 4 }}/>
            ) : (
                <WalletCards
                    addresses={addresses}
                    editingAddresses={editingAddresses}
                    onStakedChange={handleStakedChange}
                />
            )}
        </div>
    );
};

export default MyAddressesPage;
