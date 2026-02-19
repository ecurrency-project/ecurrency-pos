import { memo, useCallback, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Button, Form, Input, Modal, message } from 'antd';
import { KeyOutlined } from '@ant-design/icons';

import { useAddAddressMutation } from '@/entities/MyAddress';

export const ImportAddressButton = memo(function ImportAddressButton() {
    const { t } = useTranslation();

    const [addAddress, { isLoading: isAdding }] = useAddAddressMutation();

    const [isModalOpen, setIsModalOpen] = useState(false);
    const [form] = Form.useForm();

    const handleAdd = useCallback(async () => {
        try {
            const values = await form.validateFields();
            await addAddress(values).unwrap();
            message.success(t('Address added'));
            setIsModalOpen(false);
            form.resetFields();
        } catch {
            message.error(t('Failed to add address'));
        }
    }, [addAddress, form, t]);

    const handleCancel = useCallback(() => {
        setIsModalOpen(false);
        form.resetFields();
    }, [form]);

    return (
        <>
            <Button
                icon={<KeyOutlined/>}
                onClick={() => setIsModalOpen(true)}
            >
                {t('Import')}
            </Button>

            <Modal
                title={t('Import Address')}
                open={isModalOpen}
                onOk={handleAdd}
                onCancel={handleCancel}
                confirmLoading={isAdding}
                okText={t('Add')}
                cancelText={t('Cancel')}
            >
                <Form form={form} layout="vertical">
                    <Form.Item
                        name="address"
                        label={t('Address')}
                        rules={[{ required: true, message: t('Please enter address') }]}
                    >
                        <Input placeholder={t('Address')}/>
                    </Form.Item>
                    <Form.Item
                        name="private_key"
                        label={t('Private Key')}
                        rules={[{ required: true, message: t('Please enter private key') }]}
                    >
                        <Input.Password placeholder={t('Private Key')}/>
                    </Form.Item>
                </Form>
            </Modal>
        </>
    );
});
