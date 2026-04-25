import { Form, Input, InputNumber } from 'antd';
import { useCallback, useEffect, useState } from 'react';

import { useSendTransaction } from '@/features/SendTransaction';

import { isAddress } from '@/shared/utils';
import { Button } from '@/shared/ui/Button';
import { FORM_MAX_WIDTH, COIN_DECIMALS, SAT_PER_COIN } from '@/shared/const/const';
import { sat2btc } from '@/shared/lib/fmtbtc';
import { brand } from '@/brand';

export const FirstStep = () => {
    const { next, amountSat, targetAddress, setTargetAddress, setAmountSat } = useSendTransaction();
    const [form] = Form.useForm();
    const [submittable, setSubmittable] = useState<boolean>(false);
    const values = Form.useWatch([], form);

    useEffect(() => {
        form
            .validateFields({ validateOnly: true })
            .then(() => setSubmittable(true))
            .catch(() => setSubmittable(false));
    }, [form, values]);

    const onSubmit = useCallback(() => {
        next();
    }, [next]);

    return (
        <Form
            name="basic"
            style={{ maxWidth: FORM_MAX_WIDTH, margin: '0 auto' }}
            form={form}
            layout="vertical"
            initialValues={{ remember: true, amount: amountSat ? sat2btc(amountSat) : undefined, address: targetAddress }}
            autoComplete="off"
        >
            <Form.Item
                label="Target address:"
                name="address"
                rules={[
                    {
                        required: true,
                        message: 'Please input address!'
                    }, {
                        validator: (_, value: string) => {
                            const trimmed = value.trim();
                            if (!isAddress(trimmed)) {
                                return Promise.reject(new Error(`Please input a valid ${brand.assetName} address!`));
                            }
                            return Promise.resolve();
                        }
                    }]
                }
                validateFirst
            >
                <Input placeholder="Address" onChange={(e) => setTargetAddress(e.target.value)} style={{ width: '100%' }}/>
            </Form.Item>

            <Form.Item
                label="Amount:"
                name="amount"
                rules={[{ required: true, message: 'Please input amount!' }, {
                    type: 'number',
                    message: 'Please input only numbers!'
                }, {
                    validator: async (_, value: number | null) => {
                        if (value && value > 0) {
                            await Promise.resolve();
                        } else {
                            await Promise.reject('Please input a positive amount!');
                        }
                    }
                }]}
                validateFirst
            >
                <InputNumber
                    placeholder="Amount"
                    style={{ width: '100%' }}
                    controls={false}
                    min={0}
                    precision={COIN_DECIMALS}
                    onChange={(value) => setAmountSat(value ? Math.round(value * SAT_PER_COIN) : 0)}
                />
            </Form.Item>

            <Form.Item label={null}>
                <Button type="primary" htmlType="submit" disabled={!submittable} onClick={() => onSubmit()}>
                    Next Step
                </Button>
            </Form.Item>
        </Form>
    )
}
