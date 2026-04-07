import { memo, useCallback, useState } from 'react';
import { Button, Modal, Typography, message } from 'antd';
import { PlusOutlined, EyeOutlined, EyeInvisibleOutlined } from '@ant-design/icons';

import {
    useGenerateNewAddressMutation,
    useAddAddressMutation,
} from '@/entities/MyAddress';
import type { AddAddressParams } from '@/entities/MyAddress';

import cls from './GenerateAddressButton.module.css';

const { Text } = Typography;

export const GenerateAddressButton = memo(function GenerateAddressButton() {
    const [generateNewAddress, { isLoading: isGenerating }] = useGenerateNewAddressMutation();
    const [addAddress] = useAddAddressMutation();

    const [generatedAddress, setGeneratedAddress] = useState<AddAddressParams | null>(null);
    const [isModalOpen, setIsModalOpen] = useState(false);
    const [isKeyVisible, setIsKeyVisible] = useState(false);
    const [isSaving, setIsSaving] = useState(false);

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
            <Button
                type="primary"
                icon={<PlusOutlined/>}
                onClick={handleGenerate}
                loading={isGenerating}
            >
                Generate New
            </Button>

            <Modal
                title='Generated Address'
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
                    </div>
                )}
            </Modal>
        </>
    );
});
