import { useEffect, useState } from 'react';
import { Form, InputNumber, Modal, Select, message } from 'antd';

import { useSendTransaction } from '@/features/SendTransaction';

import { Button } from '@/shared/ui/Button';
import { formatSat } from '@/shared/utils';
import { sat2btc } from '@/shared/lib/fmtbtc';
import { FORM_MAX_WIDTH, COIN_DECIMALS, SAT_PER_COIN } from '@/shared/const/const';

import cls from './SecondStep.module.css';

export const SecondStep = () => {
    const {
        targetAddress,
        selectedAddresses,
        setSelectedAddresses,
        changeAddress,
        setChangeAddress,
        addressesData,
        prev,
        next,
        amountSat,
        setAmountSat,
        feeRate,
        setFeeRate,
        feeSat,
        createTransactionJSON,
    } = useSendTransaction();

    const [confirmOpen, setConfirmOpen] = useState(false);

    const [form] = Form.useForm();
    const [submittable, setSubmittable] = useState<boolean>(false);
    const values = Form.useWatch([], form);

    const outputOptions = Object.keys(addressesData || {}).map(address => ({
        value: address,
        label: `${address} (${addressesData?.[address].balanceFormatted})`,
    }));

    const inputOptions = Object.keys(addressesData || {}).map(address => ({
        value: address,
        label: address,
    }));

    useEffect(() => {
        form
            .validateFields({ validateOnly: true })
            .then(() => setSubmittable(true))
            .catch(() => setSubmittable(false));
    }, [form, values]);

    const totalSelectedBalance = selectedAddresses.reduce((total, address) => {
        return total + (addressesData?.[address]?.balance || 0);
    }, 0);

    const handleSelectedAddressesChange = (value: string[]) => {
        setSelectedAddresses(value);
        form.validateFields(['amount']);
    };

    const handleSubmit = () => {
        setConfirmOpen(true);
    };

    const handleConfirm = () => {
        const result = createTransactionJSON();
        if (result.success) {
            setConfirmOpen(false);
            next();
        } else {
            message.error(result.error);
        }
    };

    return (
        <>
        <Form
            name="basic"
            style={{ maxWidth: FORM_MAX_WIDTH, margin: '0 auto' }}
            form={form}
            layout="vertical"
            initialValues={{
                addresses: selectedAddresses,
                amount: amountSat ? sat2btc(amountSat) : undefined,
                changeAddress,
                remember: true
            }}
            autoComplete="off"
        >
            <Form.Item
                label="Select addresses:"
                name="addresses"
                rules={[{
                    required: true,
                    message: 'Please select at least one address!',
                }]}
                validateFirst
            >
                <Select
                    mode="multiple"
                    style={{ width: '100%' }}
                    placeholder="Select input addresses"
                    value={selectedAddresses}
                    onChange={handleSelectedAddressesChange}
                    options={outputOptions}
                />
            </Form.Item>
            <Form.Item
                label="Amount:"
                name="amount"
                rules={[
                    {
                        required: true, message: 'Please input amount!'
                    },
                    {
                        type: 'number', message: 'Please input only numbers!'
                    },
                    {
                        validator: async (_, value: number | null) => {
                            if (!value || value <= 0) {
                                await Promise.reject('Please input a positive amount!');
                            } else if (Math.round(value * SAT_PER_COIN) + feeSat > totalSelectedBalance) {
                                await Promise.reject(`Amount + fee exceeds balance (${formatSat(totalSelectedBalance)})`);
                            } else {
                                await Promise.resolve();
                            }
                        }
                    }
                ]}
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
            <Form.Item
                label="Change address:"
                name="changeAddress"
                rules={[{ required: true, message: 'Please input address of change!' }]}
                validateFirst
            >
                <Select
                    onChange={setChangeAddress}
                    value={changeAddress}
                    placeholder={'Select change address'}
                    className={cls.secondInput}
                    options={inputOptions}
                />
            </Form.Item>

            <Form.Item
                label="Fee rate (sat/B):"
                name="feeRate"
                initialValue={feeRate}
            >
                <InputNumber
                    style={{ width: '100%' }}
                    controls={false}
                    min={0}
                    precision={0}
                    onChange={(value) => setFeeRate(value ?? 0)}
                />
            </Form.Item>

            {feeSat > 0 && (
                <div className={cls.feeInfo}>
                    Estimated fee: {formatSat(feeSat)}
                </div>
            )}

            <Form.Item label={null} className={cls.buttons}>
                <Button htmlType="button" style={{ margin: '0 8px' }} onClick={prev}>
                    Previous step
                </Button>
                <Button type="primary" htmlType="submit" disabled={!submittable} onClick={handleSubmit} className={cls.sendButton}>
                    Send Transaction
                </Button>
            </Form.Item>
        </Form>

        <Modal
            title="Confirm Transaction"
            open={confirmOpen}
            onCancel={() => setConfirmOpen(false)}
            footer={[
                <Button key="cancel" onClick={() => setConfirmOpen(false)}>
                    Cancel
                </Button>,
                <Button key="confirm" type="primary" onClick={handleConfirm}>
                    Confirm
                </Button>,
            ]}
        >
            <div className={cls.summary}>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>To</span>
                    <span className={cls.summaryValue}>{targetAddress}</span>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>Amount</span>
                    <span className={cls.summaryValue}>{formatSat(amountSat)}</span>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>Fee</span>
                    <span className={cls.summaryValue}>{formatSat(feeSat)}</span>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>Total</span>
                    <span className={cls.summaryValue}>{formatSat(amountSat + feeSat)}</span>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>From</span>
                    <div className={cls.summaryValue}>
                        {selectedAddresses.map((addr) => (
                            <div key={addr}>{addr}</div>
                        ))}
                    </div>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>Change</span>
                    <span className={cls.summaryValue}>{changeAddress}</span>
                </div>
            </div>
        </Modal>
        </>
    )
};
