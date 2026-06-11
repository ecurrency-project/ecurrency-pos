import { useMemo } from 'react';

import { useSendTransaction } from '@/features/SendTransaction';

import { Button } from '@/shared/ui/Button';
import { formatSat } from '@/shared/utils';

import cls from './SecondStep.module.css';

export const SecondStep = () => {
    const {
        targetAddress,
        amountSat,
        feeSat,
        changeAddress,
        transactionJSON,
        addressesData,
        prev,
        next,
    } = useSendTransaction();

    const { fromAddresses, changeSat } = useMemo(() => {
        const spentOutpoints = new Set(
            (transactionJSON?.inputs ?? []).map((input) => `${input.txid}:${input.vout}`)
        );
        const from: string[] = [];
        let spentSumSat = 0;

        Object.entries(addressesData ?? {}).forEach(([address, data]) => {
            const spentUtxos = data.utxos.filter((utxo) => spentOutpoints.has(utxo.outpoint));
            if (spentUtxos.length) {
                from.push(address);
                spentSumSat += spentUtxos.reduce((sum, utxo) => sum + utxo.valueSat, 0);
            }
        });

        return { fromAddresses: from, changeSat: spentSumSat - amountSat - feeSat };
    }, [transactionJSON, addressesData, amountSat, feeSat]);

    return (
        <div className={cls.second}>
            <div className={cls.summary}>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>To</span>
                    <span className={cls.summaryValue}>{targetAddress.trim()}</span>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>Amount</span>
                    <span className={cls.summaryValue}>{formatSat(amountSat)}</span>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>Network fee</span>
                    <span className={cls.summaryValue}>{formatSat(feeSat)}</span>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>Total</span>
                    <span className={cls.summaryValue}>{formatSat(amountSat + feeSat)}</span>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>From</span>
                    <div className={cls.summaryValue}>
                        {fromAddresses.map((address) => (
                            <div key={address}>{address}</div>
                        ))}
                    </div>
                </div>
                {changeSat > 0 && (
                    <div className={cls.summaryRow}>
                        <span className={cls.summaryLabel}>Change</span>
                        <span className={cls.summaryValue}>
                            {changeAddress} ({formatSat(changeSat)})
                        </span>
                    </div>
                )}
            </div>

            <div className={cls.buttons}>
                <Button htmlType="button" onClick={prev}>
                    Previous step
                </Button>
                <Button type="primary" onClick={next}>
                    Confirm and send
                </Button>
            </div>
        </div>
    );
};
