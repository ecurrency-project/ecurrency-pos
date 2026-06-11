import { useEffect, useState } from 'react';
import { Alert, Form, Input, Skeleton, message } from 'antd';

import { Button } from '@/shared/ui/Button';
import { FORM_MAX_WIDTH } from '@/shared/const/const';

import { useGetPasswordStatusQuery, useSetWalletPasswordMutation } from '../../api/walletPasswordApi';

import cls from './WalletPasswordForm.module.css';

const MAX_PASSWORD_LENGTH = 1024;

interface PasswordFormValues {
    currentPassword?: string;
    password: string;
    confirm: string;
}

export const WalletPasswordForm = () => {
    const [form] = Form.useForm<PasswordFormValues>();
    const [submittable, setSubmittable] = useState<boolean>(false);
    const values = Form.useWatch([], form);

    const { data: status, error: statusError, isLoading: isStatusLoading } = useGetPasswordStatusQuery();
    const [setWalletPassword, { isLoading: isSaving }] = useSetWalletPasswordMutation();

    useEffect(() => {
        form
            .validateFields({ validateOnly: true })
            .then(() => setSubmittable(true))
            .catch(() => setSubmittable(false));
    }, [form, values]);

    const isUnauthorized = statusError != null && 'status' in statusError && statusError.status === 401;
    const passwordSet = status?.password_set === true || isUnauthorized;

    const onFinish = async (values: PasswordFormValues) => {
        try {
            await setWalletPassword({
                password: values.password,
                currentPassword: passwordSet ? values.currentPassword : undefined,
            }).unwrap();

            message.success(passwordSet ? 'Password changed successfully' : 'Password set successfully');
            form.resetFields();
        } catch (e) {
            const httpStatus = typeof e === 'object' && e !== null && 'status' in e
                ? (e as { status?: number | string }).status
                : undefined;

            if (httpStatus === 401) {
                message.error('Current password is incorrect');
            } else if (httpStatus === 400) {
                message.error(`Password must be non-empty and at most ${MAX_PASSWORD_LENGTH} characters`);
            } else {
                message.error('Failed to save password');
            }
        }
    };

    if (isStatusLoading) {
        return <Skeleton active paragraph={{ rows: 3 }} />;
    }

    return (
        <Form
            form={form}
            layout="vertical"
            style={{ maxWidth: FORM_MAX_WIDTH }}
            onFinish={onFinish}
            autoComplete="off"
        >
            <Alert
                className={cls.info}
                type="info"
                showIcon
                message={
                    passwordSet
                        ? 'A wallet password is set. Admin and wallet pages require HTTP Basic credentials: any username, this password.'
                        : 'No wallet password is set. After you set one, the browser will ask for credentials on admin and wallet pages: any username, this password.'
                }
            />

            {passwordSet && (
                <Form.Item
                    label="Current password:"
                    name="currentPassword"
                    rules={[{ required: true, message: 'Please input the current password!' }]}
                >
                    <Input.Password placeholder="Current password" />
                </Form.Item>
            )}

            <Form.Item
                label="New password:"
                name="password"
                rules={[
                    { required: true, message: 'Please input a password!' },
                    { max: MAX_PASSWORD_LENGTH, message: `Password must be at most ${MAX_PASSWORD_LENGTH} characters!` },
                ]}
                validateFirst
            >
                <Input.Password placeholder="New password" />
            </Form.Item>

            <Form.Item
                label="Confirm new password:"
                name="confirm"
                dependencies={['password']}
                rules={[
                    { required: true, message: 'Please confirm the password!' },
                    ({ getFieldValue }) => ({
                        validator(_, value: string) {
                            if (!value || getFieldValue('password') === value) {
                                return Promise.resolve();
                            }
                            return Promise.reject(new Error('Passwords do not match!'));
                        },
                    }),
                ]}
                validateFirst
            >
                <Input.Password placeholder="Repeat new password" />
            </Form.Item>

            <Form.Item label={null}>
                <Button type="primary" htmlType="submit" disabled={!submittable} loading={isSaving}>
                    {passwordSet ? 'Change password' : 'Set password'}
                </Button>
            </Form.Item>
        </Form>
    );
};
