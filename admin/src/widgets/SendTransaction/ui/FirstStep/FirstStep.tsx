import { useEffect, useState } from 'react';
import { Alert, Form, Input, InputNumber, Select, message } from 'antd';

import { assessFee, assessTokenFee, parseTokenAmount, useSendTransaction, NATIVE_ASSET_ID } from '@/features/SendTransaction';
import { formatTokenAmount } from '@/entities/Token';

import { isAddress, formatSat } from '@/shared/utils';
import { Button } from '@/shared/ui/Button';
import { FORM_MAX_WIDTH, COIN_DECIMALS, SAT_PER_COIN } from '@/shared/const/const';
import { sat2btc } from '@/shared/lib/fmtbtc';
import { brand } from '@/brand';

import { AssetOptionLabel } from './AssetOptionLabel';

import cls from './FirstStep.module.css';

export const FirstStep = () => {
    const {
        next,
        targetAddress,
        setTargetAddress,
        amountSat,
        setAmountSat,
        tokenAmount,
        setTokenAmount,
        selectedAddresses,
        setSelectedAddresses,
        changeAddress,
        setChangeAddress,
        feeSat,
        suggestedFeeSat,
        isFeeManual,
        setFeeSat,
        assetId,
        setAssetId,
        isTokenMode,
        tokenTicker,
        tokenDecimals,
        selectedTokenBalance,
        tokenTotals,
        addressesData,
        createTransactionJSON,
    } = useSendTransaction();

    const [form] = Form.useForm();
    const [submittable, setSubmittable] = useState<boolean>(false);
    const values = Form.useWatch([], form);

    const assetOptions = [
        { value: NATIVE_ASSET_ID, label: `${brand.assetLabel} (native)` },
        ...Object.entries(tokenTotals).map(([tokenId, total]) => ({
            value: tokenId,
            label: <AssetOptionLabel tokenId={tokenId} total={total} />,
        })),
    ];

    const sourceOptions = Object.keys(addressesData || {}).map(address => {
        if (!isTokenMode) {
            return {
                value: address,
                label: `${address} (${addressesData?.[address].balanceFormatted})`,
            };
        }
        const group = addressesData?.[address]?.tokens?.[assetId];
        const label = group
            ? `${address} (${formatTokenAmount(group.amount.toString(), tokenDecimals)}${tokenTicker ? ` ${tokenTicker}` : ''})`
            : `${address} (fees only)`;
        return { value: address, label };
    });

    const changeOptions = Object.keys(addressesData || {}).map(address => ({
        value: address,
        label: address,
    }));

    useEffect(() => {
        form
            .validateFields({ validateOnly: true })
            .then(() => setSubmittable(true))
            .catch(() => setSubmittable(false));
    }, [form, values]);

    useEffect(() => {
        if (!isFeeManual) {
            form.setFieldValue('fee', suggestedFeeSat > 0 ? sat2btc(suggestedFeeSat) : undefined);
            form.validateFields(['fee'], { validateOnly: true }).catch(() => {});
        }
    }, [form, suggestedFeeSat, isFeeManual]);

    const totalSelectedBalance = selectedAddresses.reduce((total, address) => {
        return total + (addressesData?.[address]?.balance || 0);
    }, 0);

    // Native available for the fee in token mode: spendable native UTXOs plus
    // the native value carried by the token UTXOs that will be spent anyway.
    const nativeCarriedSat = isTokenMode
        ? selectedAddresses
            .flatMap((address) => addressesData?.[address]?.tokens?.[assetId]?.utxos ?? [])
            .reduce((sum, utxo) => sum + utxo.valueSat, 0)
        : 0;
    const nativeAvailableForFeeSat = totalSelectedBalance + nativeCarriedSat;

    const feeAssessment = isTokenMode
        ? assessTokenFee(feeSat, suggestedFeeSat)
        : assessFee(amountSat, feeSat);

    const handleSelectedAddressesChange = (value: string[]) => {
        setSelectedAddresses(value);
        form.validateFields(['amount', 'fee']).catch(() => {});
    };

    const handleAssetChange = (value: string) => {
        setAssetId(value);
        form.setFieldValue('amount', undefined);
        form.validateFields(['fee'], { validateOnly: true }).catch(() => {});
    };

    const handleSubmit = () => {
        const result = createTransactionJSON();
        if (result.success) {
            next();
        } else {
            message.error(result.error);
        }
    };

    return (
        <Form
            name="basic"
            style={{ maxWidth: FORM_MAX_WIDTH, margin: '0 auto' }}
            form={form}
            layout="vertical"
            initialValues={{
                asset: assetId,
                address: targetAddress,
                amount: isTokenMode
                    ? (tokenAmount || undefined)
                    : (amountSat ? sat2btc(amountSat) : undefined),
                addresses: selectedAddresses,
                changeAddress: changeAddress || undefined,
                remember: true
            }}
            autoComplete="off"
        >
            <Form.Item label="Asset:" name="asset">
                <Select
                    options={assetOptions}
                    onChange={handleAssetChange}
                    style={{ width: '100%' }}
                />
            </Form.Item>

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

            {isTokenMode ? (
                <Form.Item
                    label="Amount:"
                    name="amount"
                    rules={[
                        {
                            required: true, message: 'Please input amount!'
                        },
                        {
                            validator: async (_, value: string | null) => {
                                if (value == null || value === '') return;
                                const parsed = parseTokenAmount(String(value), tokenDecimals);
                                if (!parsed.ok) {
                                    if (parsed.error === 'too_many_decimals') {
                                        await Promise.reject(`Max ${tokenDecimals} decimal places for this token`);
                                    }
                                    await Promise.reject('Please input a positive amount!');
                                } else if (selectedAddresses.length && parsed.value > selectedTokenBalance) {
                                    await Promise.reject(
                                        `Amount exceeds token balance (${formatTokenAmount(selectedTokenBalance.toString(), tokenDecimals)}${tokenTicker ? ` ${tokenTicker}` : ''})`
                                    );
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
                        stringMode
                        min="0"
                        precision={tokenDecimals}
                        addonAfter={tokenTicker || undefined}
                        onChange={(value) => setTokenAmount(value != null ? String(value) : '')}
                    />
                </Form.Item>
            ) : (
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
                                } else if (selectedAddresses.length && Math.round(value * SAT_PER_COIN) + feeSat > totalSelectedBalance) {
                                    await Promise.reject(`Amount + fee exceeds balance (${formatSat(totalSelectedBalance)})`);
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
            )}

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
                    options={sourceOptions}
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
                    placeholder="Select change address"
                    options={changeOptions}
                />
            </Form.Item>

            <Form.Item
                label="Network fee:"
                name="fee"
                extra={isTokenMode ? `The network fee is always paid in ${brand.assetLabel}.` : undefined}
                rules={[
                    { required: true, message: 'Please input fee!' },
                    {
                        validator: async (_, value: number | null) => {
                            if (value == null) return;
                            const valueSat = Math.round(Number(value) * SAT_PER_COIN);
                            if (suggestedFeeSat > 0 && valueSat < suggestedFeeSat) {
                                await Promise.reject(`Fee is below the network minimum (${formatSat(suggestedFeeSat)})`);
                            }
                            if (isTokenMode && selectedAddresses.length && valueSat > nativeAvailableForFeeSat) {
                                await Promise.reject(
                                    `Not enough ${brand.assetLabel} for the fee (available ${formatSat(nativeAvailableForFeeSat)})`
                                );
                            }
                        }
                    }
                ]}
                validateFirst
            >
                <InputNumber
                    style={{ width: '100%' }}
                    controls={false}
                    min={0}
                    precision={COIN_DECIMALS}
                    step={0.00000001}
                    onChange={(value) => {
                        setFeeSat(value != null ? Math.round(Number(value) * SAT_PER_COIN) : null);
                    }}
                />
            </Form.Item>

            {feeAssessment.level !== 'ok' && feeAssessment.message && (
                <Alert
                    className={cls.feeAlert}
                    type={feeAssessment.level === 'block' ? 'error' : 'warning'}
                    showIcon
                    message={feeAssessment.message}
                />
            )}

            <Form.Item label={null}>
                <Button
                    type="primary"
                    htmlType="submit"
                    disabled={!submittable || feeAssessment.level === 'block'}
                    onClick={handleSubmit}
                >
                    Next Step
                </Button>
            </Form.Item>
        </Form>
    )
}
