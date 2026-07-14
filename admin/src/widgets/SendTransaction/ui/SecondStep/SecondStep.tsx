import { useMemo } from 'react';

import { useSendTransaction } from '@/features/SendTransaction';
import { formatTokenAmount } from '@/entities/Token';

import { Button } from '@/shared/ui/Button';
import { formatSat } from '@/shared/utils';
import { brand } from '@/brand';

import cls from './SecondStep.module.css';

export const SecondStep = () => {
    const {
        targetAddress,
        amountSat,
        feeSat,
        changeAddress,
        transactionJSON,
        addressesData,
        isTokenMode,
        assetId,
        tokenTicker,
        tokenDecimals,
        prev,
        next,
    } = useSendTransaction();

    const trimmedTarget = targetAddress.trim();

    const { fromAddresses, changeSat } = useMemo(() => {
        const spentOutpoints = new Set(
            (transactionJSON?.inputs ?? []).map((input) => `${input.txid}:${input.vout}`)
        );
        const from: string[] = [];
        let spentSumSat = 0;

        Object.entries(addressesData ?? {}).forEach(([address, data]) => {
            const spentUtxos = data.utxos.filter((utxo) => spentOutpoints.has(utxo.outpoint));
            const spentTokenUtxos = isTokenMode
                ? (data.tokens?.[assetId]?.utxos ?? []).filter((utxo) => spentOutpoints.has(utxo.outpoint))
                : [];
            if (spentUtxos.length || spentTokenUtxos.length) {
                from.push(address);
                spentSumSat += spentUtxos.reduce((sum, utxo) => sum + utxo.valueSat, 0);
                spentSumSat += spentTokenUtxos.reduce((sum, utxo) => sum + utxo.valueSat, 0);
            }
        });

        return {
            fromAddresses: from,
            // Token tx: all spent native goes to fee + native change (the token
            // outputs carry 0 native). Native tx: minus the amount as well.
            changeSat: isTokenMode
                ? spentSumSat - feeSat
                : spentSumSat - amountSat - feeSat,
        };
    }, [transactionJSON, addressesData, amountSat, feeSat, isTokenMode, assetId]);

    // Token amounts, read back from the built transaction (source of truth).
    const { tokenSent, tokenChange } = useMemo(() => {
        if (!isTokenMode) return { tokenSent: '', tokenChange: '' };

        let sent = '';
        let change = '';
        (transactionJSON?.outputs ?? []).forEach((output) => {
            if (!('token_id' in output)) return;
            const amount = String(output.token_amount ?? '');
            if (trimmedTarget in output) sent = amount;
            else if (changeAddress in output) change = amount;
        });

        return { tokenSent: sent, tokenChange: change };
    }, [isTokenMode, transactionJSON, trimmedTarget, changeAddress]);

    const ticker = tokenTicker ? ` ${tokenTicker}` : '';

    return (
        <div className={cls.second}>
            <div className={cls.summary}>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>To</span>
                    <span className={cls.summaryValue}>{trimmedTarget}</span>
                </div>
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>Amount</span>
                    <span className={cls.summaryValue} translate="no">
                        {isTokenMode
                            ? `${formatTokenAmount(tokenSent || '0', tokenDecimals)}${ticker}`
                            : formatSat(amountSat)}
                    </span>
                </div>
                {isTokenMode && tokenChange && (
                    <div className={cls.summaryRow}>
                        <span className={cls.summaryLabel}>Token change</span>
                        <span className={cls.summaryValue} translate="no">
                            {formatTokenAmount(tokenChange, tokenDecimals)}{ticker}
                        </span>
                    </div>
                )}
                <div className={cls.summaryRow}>
                    <span className={cls.summaryLabel}>Network fee</span>
                    <span className={cls.summaryValue} translate="no">{formatSat(feeSat)}</span>
                </div>
                {!isTokenMode && (
                    <div className={cls.summaryRow}>
                        <span className={cls.summaryLabel}>Total</span>
                        <span className={cls.summaryValue} translate="no">{formatSat(amountSat + feeSat)}</span>
                    </div>
                )}
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
                        <span className={cls.summaryLabel}>{isTokenMode ? `${brand.assetLabel} change` : 'Change'}</span>
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
