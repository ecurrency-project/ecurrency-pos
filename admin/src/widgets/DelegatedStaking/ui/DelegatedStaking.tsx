import { useCallback, useState } from 'react';
import { Link } from 'react-router-dom';
import {
    Alert,
    Button,
    Form,
    Input,
    Modal,
    Popconfirm,
    Select,
    Table,
    Typography,
    message,
} from 'antd';
import { DeleteOutlined, KeyOutlined, PlusOutlined, SafetyOutlined } from '@ant-design/icons';
import type { ColumnsType } from 'antd/es/table';

import {
    useGetStakingKeysQuery,
    useNewStakingKeyMutation,
    useGetDelegationsQuery,
    useAddDelegationMutation,
    useRemoveDelegationMutation,
} from '@/entities/Delegation';
import type { IDelegation } from '@/entities/Delegation';
import { AddressBalance } from '@/entities/Address';

import { RouterPath } from '@/shared/config/router/router';

import cls from './DelegatedStaking.module.css';

const { Text } = Typography;

const shortHash = (hash: string) =>
    hash.length > 18 ? `${hash.slice(0, 8)}…${hash.slice(-6)}` : hash;

export const DelegatedStaking = () => {
    const { data: stakingKeys, isLoading: keysLoading } = useGetStakingKeysQuery();
    const { data: delegations } = useGetDelegationsQuery();

    const [newStakingKey, { isLoading: isCreatingKey }] = useNewStakingKeyMutation();
    const [addDelegation, { isLoading: isAdding }] = useAddDelegationMutation();
    const [removeDelegation] = useRemoveDelegationMutation();

    const [isAddModalOpen, setIsAddModalOpen] = useState(false);
    const [addForm] = Form.useForm();

    const handleNewKey = useCallback(async () => {
        try {
            const result = await newStakingKey().unwrap();
            if (result.warning) {
                message.warning(`Staking key created; ${result.warning}`);
            } else {
                message.success('Staking key created');
            }
        } catch {
            message.error('Failed to create the staking key (is the wallet locked?)');
        }
    }, [newStakingKey]);

    const handleAddDelegation = useCallback(async () => {
        let values;
        try {
            values = await addForm.validateFields();
        } catch {
            return; // validation errors are shown by the form
        }
        try {
            const result = await addDelegation({
                owner_pubkeyhash: values.owner_pubkeyhash.trim(),
                ...(values.staking_pubkeyhash ? { staking_pubkeyhash: values.staking_pubkeyhash } : {}),
            }).unwrap();
            message.success(`Delegation address ${result.address} added`);
            setIsAddModalOpen(false);
            addForm.resetFields();
        } catch {
            message.error('Failed to add the delegation: check the owner pubkeyhash');
        }
    }, [addDelegation, addForm]);

    const handleRemove = useCallback(async (address: string) => {
        try {
            await removeDelegation(address).unwrap();
            message.success('Delegation removed');
        } catch {
            message.error('Failed to remove the delegation');
        }
    }, [removeDelegation]);

    const columns: ColumnsType<IDelegation> = [
        {
            title: 'Address',
            dataIndex: 'address',
            key: 'address',
            render: (addr: string) => (
                <Link to={RouterPath.address.replace(':id', addr)} translate="no">{addr}</Link>
            ),
        },
        {
            title: 'Owner pubkeyhash',
            dataIndex: 'owner_pubkeyhash',
            key: 'owner_pubkeyhash',
            render: (hash: string) => (
                <Text copyable={{ text: hash }} translate="no">{shortHash(hash)}</Text>
            ),
        },
        ...(stakingKeys && stakingKeys.length > 1 ? [{
            title: 'Staking key',
            dataIndex: 'staking_pubkeyhash',
            key: 'staking_pubkeyhash',
            render: (hash: string) => <Text translate="no">{shortHash(hash)}</Text>,
        }] : []),
        {
            title: 'Balance',
            key: 'balance',
            align: 'right' as const,
            width: 180,
            render: (_: unknown, record: IDelegation) => (
                <AddressBalance address={record.address} />
            ),
        },
        {
            title: '',
            key: 'actions',
            width: 60,
            align: 'center' as const,
            render: (_: unknown, record: IDelegation) => (
                <Popconfirm
                    title="Stop staking this address?"
                    description="The owner keeps the coins; they just stop being staked here."
                    onConfirm={() => handleRemove(record.address)}
                >
                    <Button type="text" danger size="small" icon={<DeleteOutlined/>} aria-label="Remove delegation"/>
                </Popconfirm>
            ),
        },
    ];

    return (
        <section className={cls.DelegatedStaking}>
            <div className={cls.header}>
                <div className={cls.headerLeft}>
                    <SafetyOutlined/>
                    <span className={cls.headerTitle}>Delegated Staking</span>
                    {!!delegations?.length && (
                        <span className={cls.count}>({delegations.length})</span>
                    )}
                </div>
                <div className={cls.headerActions}>
                    {!!stakingKeys?.length && (
                        <Button
                            type="primary"
                            icon={<PlusOutlined/>}
                            onClick={() => setIsAddModalOpen(true)}
                        >
                            Add Delegation
                        </Button>
                    )}
                </div>
            </div>

            <p className={cls.description}>
                Stake coins for their owners without being able to spend them: the owner builds
                a covenant address from your staking pubkeyhash, and your node can only return
                the staked value back to that address.
            </p>

            {!keysLoading && !stakingKeys?.length && (
                <div className={cls.noKey}>
                    <Button
                        icon={<KeyOutlined/>}
                        loading={isCreatingKey}
                        onClick={handleNewKey}
                    >
                        Create Staking Key
                    </Button>
                    <span className={cls.noKeyHint}>
                        A staking key is created once; publish its pubkeyhash for the coin owners.
                    </span>
                </div>
            )}

            {!!stakingKeys?.length && (
                <div className={cls.keys}>
                    {stakingKeys.map((key) => (
                        <div key={key.pubkeyhash} className={cls.keyRow}>
                            <Text type="secondary">Staking pubkeyhash (publish it for the owners):</Text>
                            <Text copyable className={cls.keyValue} translate="no">{key.pubkeyhash}</Text>
                        </div>
                    ))}
                </div>
            )}

            {!!delegations?.length && (
                <Table
                    className={cls.table}
                    columns={columns}
                    dataSource={delegations}
                    rowKey="address"
                    size="small"
                    pagination={false}
                />
            )}

            <Modal
                title='Add Delegation'
                open={isAddModalOpen}
                onOk={handleAddDelegation}
                onCancel={() => setIsAddModalOpen(false)}
                confirmLoading={isAdding}
                okText='Add'
            >
                <Alert
                    className={cls.addAlert}
                    type="warning"
                    showIcon
                    message="The address must be staked by one node only. If the owner gave the
                        same delegation to someone else too, staking it here leads to equivocation
                        and the slashing penalty."
                />
                <Form form={addForm} layout="vertical">
                    <Form.Item
                        name="owner_pubkeyhash"
                        label='Owner pubkeyhash'
                        extra='Received from the coins owner'
                        rules={[{ required: true, message: 'Please enter the owner pubkeyhash' }]}
                    >
                        <Input placeholder='Owner pubkeyhash'/>
                    </Form.Item>
                    {stakingKeys && stakingKeys.length > 1 && (
                        <Form.Item
                            name="staking_pubkeyhash"
                            label='Staking key'
                            rules={[{ required: true, message: 'Please select the staking key' }]}
                        >
                            <Select
                                options={stakingKeys.map((key) => ({
                                    value: key.pubkeyhash,
                                    label: shortHash(key.pubkeyhash),
                                }))}
                            />
                        </Form.Item>
                    )}
                </Form>
            </Modal>
        </section>
    );
};
