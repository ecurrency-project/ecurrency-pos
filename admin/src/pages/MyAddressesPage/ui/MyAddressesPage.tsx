import { useCallback, useState } from 'react';
import { Card, Skeleton, Table, message } from 'antd';
import { WalletOutlined } from '@ant-design/icons';
import classNames from 'classnames';

import {
    useGetMyAddressesQuery,
    useEditAddressStakedMutation,
    useMyAddressColumns,
    MyAddressMobileCard,
} from '@/entities/MyAddress';
import { GenerateAddressButton } from '@/features/GenerateAddress';
import { ImportAddressButton } from '@/features/ImportAddress';

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

    const columns = useMyAddressColumns({ editingAddresses, onStakedChange: handleStakedChange });

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
                <GenerateAddressButton/>
                <ImportAddressButton/>
            </div>
        </div>
    );

    if (isLoading) {
        return (
            <div className={classNames(cls.MyAddressesPage, 'container')}>
                <Card className={cls.card}>
                    {header}
                    <Skeleton active paragraph={{ rows: 4 }}/>
                </Card>
            </div>
        );
    }

    return (
        <div className={classNames(cls.MyAddressesPage, 'container')}>
            <Card className={cls.card}>
                {header}

                <div className={cls.desktopTable}>
                    <Table
                        dataSource={addresses}
                        columns={columns}
                        rowKey="address"
                        size="small"
                        pagination={false}
                    />
                </div>

                <div className={cls.mobileList}>
                    {addresses?.map((addr) => (
                        <MyAddressMobileCard
                            key={addr.address}
                            address={addr}
                            loading={editingAddresses.has(addr.address)}
                            onStakedChange={handleStakedChange}
                        />
                    ))}
                </div>
            </Card>
        </div>
    );
};

export default MyAddressesPage;
