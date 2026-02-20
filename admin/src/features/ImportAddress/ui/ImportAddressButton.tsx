import { memo, useCallback, useState } from 'react';
import { Button, Form, Input, Modal, message } from 'antd';
import { KeyOutlined } from '@ant-design/icons';

import { useAddAddressMutation } from '@/entities/MyAddress';

export const ImportAddressButton = memo(function ImportAddressButton() {
    const [addAddress, { isLoading: isAdding }] = useAddAddressMutation();

    const [isModalOpen, setIsModalOpen] = useState(false);
    const [form] = Form.useForm();

    const handleAdd = useCallback(async () => {
        try {
            const values = await form.validateFields();
            await addAddress(values).unwrap();
            message.success('Address added');
            setIsModalOpen(false);
            form.resetFields();
        } catch {
            message.error('Failed to add address');
        }
    }, [addAddress, form]);

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
                Import
            </Button>

            <Modal
                title='Import Address'
                open={isModalOpen}
                onOk={handleAdd}
                onCancel={handleCancel}
                confirmLoading={isAdding}
                okText='Add'
                cancelText='Cancel'
            >
                <Form form={form} layout="vertical">
                    <Form.Item
                        name="address"
                        label='Address'
                        rules={[{ required: true, message: 'Please enter address' }]}
                    >
                        <Input placeholder='Address'/>
                    </Form.Item>
                    <Form.Item
                        name="private_key"
                        label='Private Key'
                        rules={[{ required: true, message: 'Please enter private key' }]}
                    >
                        <Input.Password placeholder='Private Key'/>
                    </Form.Item>
                </Form>
            </Modal>
        </>
    );
});
