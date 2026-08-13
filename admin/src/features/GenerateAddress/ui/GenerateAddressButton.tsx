import { memo, useCallback, useState } from 'react';
import { Alert, Button, Dropdown, Form, Input, Modal, Typography, message } from 'antd';
import { PlusOutlined, EyeOutlined, EyeInvisibleOutlined, DownOutlined } from '@ant-design/icons';

import {
    useGenerateNewAddressMutation,
    useAddAddressMutation,
} from '@/entities/MyAddress';
import type { GeneratedAddress } from '@/entities/MyAddress';

import cls from './GenerateAddressButton.module.css';

const { Text } = Typography;

export const GenerateAddressButton = memo(function GenerateAddressButton() {
    const [generateNewAddress, { isLoading: isGenerating }] = useGenerateNewAddressMutation();
    const [addAddress] = useAddAddressMutation();

    const [generatedAddress, setGeneratedAddress] = useState<GeneratedAddress | null>(null);
    const [isModalOpen, setIsModalOpen] = useState(false);
    const [isKeyVisible, setIsKeyVisible] = useState(false);
    const [isSaving, setIsSaving] = useState(false);
    const [isDelegateModalOpen, setIsDelegateModalOpen] = useState(false);
    const [delegateForm] = Form.useForm();

    const handleGenerate = useCallback(async () => {
        try {
            const result = await generateNewAddress().unwrap();
            setGeneratedAddress(result);
            setIsKeyVisible(false);
            setIsModalOpen(true);
        } catch {
            message.error('Failed to generate address');
        }
    }, [generateNewAddress]);

    const handleGenerateDelegated = useCallback(async () => {
        let values;
        try {
            values = await delegateForm.validateFields();
        } catch {
            return; // validation errors are shown by the form
        }
        try {
            const result = await generateNewAddress({
                delegate_pubkeyhash: values.delegate_pubkeyhash.trim(),
            }).unwrap();
            setIsDelegateModalOpen(false);
            delegateForm.resetFields();
            setGeneratedAddress(result);
            setIsKeyVisible(false);
            setIsModalOpen(true);
        } catch {
            message.error('Failed to generate address: check the delegate pubkeyhash');
        }
    }, [delegateForm, generateNewAddress]);

    const handleSave = useCallback(async () => {
        if (!generatedAddress) return;
        setIsSaving(true);
        try {
            await addAddress({
                address: generatedAddress.address,
                private_key: generatedAddress.private_key,
            }).unwrap();
            message.success('Address saved');
            setIsModalOpen(false);
            setGeneratedAddress(null);
        } catch {
            message.error('Failed to save address');
        } finally {
            setIsSaving(false);
        }
    }, [addAddress, generatedAddress]);

    const handleClose = useCallback(() => {
        setIsModalOpen(false);
        setGeneratedAddress(null);
    }, []);

    return (
        <>
            <Dropdown.Button
                type="primary"
                icon={<DownOutlined/>}
                onClick={handleGenerate}
                loading={isGenerating}
                menu={{
                    items: [{
                        key: 'delegated',
                        label: 'Delegated staking address…',
                        onClick: () => setIsDelegateModalOpen(true),
                    }],
                }}
            >
                <PlusOutlined/> Generate New
            </Dropdown.Button>

            <Modal
                title='Generate Delegated Staking Address'
                open={isDelegateModalOpen}
                onOk={handleGenerateDelegated}
                onCancel={() => setIsDelegateModalOpen(false)}
                confirmLoading={isGenerating}
                okText='Generate'
            >
                <Form form={delegateForm} layout="vertical">
                    <Form.Item
                        name="delegate_pubkeyhash"
                        label='Delegate staking pubkeyhash'
                        extra='Published by the delegate who will stake the coins for you'
                        rules={[{ required: true, message: 'Please enter the delegate pubkeyhash' }]}
                    >
                        <Input placeholder='Staking pubkeyhash'/>
                    </Form.Item>
                </Form>
            </Modal>

            <Modal
                title={generatedAddress?.pubkeyhash ? 'Generated Delegated Address' : 'Generated Address'}
                open={isModalOpen}
                onCancel={handleClose}
                width={600}
                footer={[
                    <Button key="cancel" onClick={handleClose}>
                        Cancel
                    </Button>,
                    <Button
                        key="save"
                        type="primary"
                        loading={isSaving}
                        onClick={handleSave}
                    >
                        Save
                    </Button>,
                ]}
            >
                {generatedAddress && (
                    <div className={cls.generatedInfo}>
                        <div className={cls.generatedField}>
                            <Text type="secondary">Address</Text>
                            <Text copyable className={cls.generatedValue}>
                                {generatedAddress.address}
                            </Text>
                        </div>
                        <div className={cls.generatedField}>
                            <Text type="secondary">Private Key</Text>
                            <div className={cls.privateKeyRow}>
                                {isKeyVisible ? (
                                    <Text copyable className={cls.generatedValue}>
                                        {generatedAddress.private_key}
                                    </Text>
                                ) : (
                                    <Text className={cls.generatedValue}>
                                        {'•'.repeat(32)}
                                    </Text>
                                )}
                                <Button
                                    type="text"
                                    size="small"
                                    icon={isKeyVisible ? <EyeInvisibleOutlined/> : <EyeOutlined/>}
                                    onClick={() => setIsKeyVisible(!isKeyVisible)}
                                />
                            </div>
                        </div>
                        {generatedAddress.pubkeyhash && (
                            <>
                                <div className={cls.generatedField}>
                                    <Text type="secondary">Your pubkeyhash (send it to the delegate)</Text>
                                    <Text copyable className={cls.generatedValue}>
                                        {generatedAddress.pubkeyhash}
                                    </Text>
                                </div>
                                <Alert
                                    type="warning"
                                    showIcon
                                    message="Delegated staking address"
                                    description="The delegate can only stake the coins and must always return the
                                        full value back to this address; only your private key can spend them.
                                        Send your pubkeyhash to the delegate so their node starts staking.
                                        Note that the coins are the slashing collateral: if the delegate's node
                                        equivocates (e.g. runs its staking key on two nodes at once), the penalty
                                        is paid from them - choose a delegate you trust to operate a single node."
                                />
                            </>
                        )}
                    </div>
                )}
            </Modal>
        </>
    );
});
