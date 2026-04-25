import { createContext, type FC, type ReactNode, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import { useGetFeeEstimateQuery } from '@/entities/Transaction';

import type { TransactionJSON, TransactionStatus } from '../types/types';
import { useWalletUtxoData } from '../../lib/useWalletUtxoData';
import { createTransactionJSON as buildTransaction, type CreateTransactionJSONResult } from '../../lib/createTransactionJSON';

export interface AddressData {
    balance: number;
    balanceFormatted: string;
    utxos: string[];
}

interface SendTransactionContextValue {
    step: number;
    next: () => void;
    prev: () => void;

    targetAddress: string;
    setTargetAddress: (value: string) => void;
    amountSat: number;
    setAmountSat: (value: number) => void;
    selectedAddresses: string[];
    setSelectedAddresses: (value: string[]) => void;
    feeRate: number;
    setFeeRate: (value: number) => void;
    feeSat: number;
    changeAddress: string;
    setChangeAddress: (value: string) => void;

    feeEstimate?: Record<string, number>;
    addressesData?: Record<string, AddressData>;
    isUtxoLoading: boolean;
    isUtxoError: boolean;
    transactionJSON?: TransactionJSON;
    createTransactionJSON: () => CreateTransactionJSONResult;
    transactionStatus: TransactionStatus;
    setTransactionStatus: (value: TransactionStatus) => void;
}

const SendTransactionContext = createContext<SendTransactionContextValue | null>(null);

interface SendTransactionProviderProps {
    children: ReactNode;
}

export const SendTransactionProvider: FC<SendTransactionProviderProps> = ({ children }) => {
    const [step, setStep] = useState(0);

    const [transactionStatus, setTransactionStatus] = useState<TransactionStatus>('process');
    const [targetAddress, setTargetAddress] = useState('');
    const [amountSat, setAmountSat] = useState(0);
    const [selectedAddresses, setSelectedAddresses] = useState<string[]>([]);
    const [feeRate, setFeeRate] = useState(0);
    const [isFeeRateManual, setIsFeeRateManual] = useState(false);
    const [changeAddress, setChangeAddress] = useState('');
    const [transactionJSON, setTransactionJSON] = useState<TransactionJSON | undefined>();

    const { addressesData, isLoading: isUtxoLoading, isError: isUtxoError } = useWalletUtxoData();
    const { data: feeEstimate } = useGetFeeEstimateQuery(undefined, {
        pollingInterval: 60_000,
    });

    useEffect(() => {
        if (feeEstimate && !isFeeRateManual) {
            const defaultRate = feeEstimate['3'] ?? feeEstimate['1'] ?? Object.values(feeEstimate)[0];
            if (defaultRate) setFeeRate(Math.ceil(defaultRate));
        }
    }, [feeEstimate, isFeeRateManual]);

    const handleSetFeeRate = useCallback((value: number) => {
        setIsFeeRateManual(true);
        setFeeRate(value);
    }, []);

    const feeSat = useMemo(() => {
        if (!feeEstimate || !addressesData) return 0;

        const inputCount = selectedAddresses.reduce((count, address) => {
            return count + (addressesData[address]?.utxos.length || 0);
        }, 0);
        // 1 output (target) + possible change output
        const outputCount = 2;
        // Rough tx size: ~148 bytes per input + ~34 bytes per output + ~10 bytes overhead
        const estimatedSize = inputCount * 148 + outputCount * 34 + 10;

        return Math.ceil(estimatedSize * feeRate);
    }, [feeEstimate, addressesData, selectedAddresses, feeRate]);

    const next = useCallback(() => {
        setStep((s) => s + 1);
    }, []);

    const prev = useCallback(() => {
        setStep((s) => s - 1);
    }, []);

    const createTransactionJSON = useCallback((): CreateTransactionJSONResult => {
        const result = buildTransaction({
            targetAddress,
            amountSat,
            feeSat,
            selectedAddresses,
            changeAddress,
            addressesData,
        });

        if (result.success) {
            setTransactionJSON(result.data);
        }

        return result;
    }, [targetAddress, amountSat, feeSat, selectedAddresses, changeAddress, addressesData]);

    const value: SendTransactionContextValue = {
        step,
        next,
        prev,
        targetAddress,
        setTargetAddress,
        amountSat,
        setAmountSat,
        selectedAddresses,
        setSelectedAddresses,
        feeRate,
        setFeeRate: handleSetFeeRate,
        feeSat,
        changeAddress,
        setChangeAddress,
        feeEstimate,
        addressesData,
        isUtxoLoading,
        isUtxoError,
        transactionJSON,
        createTransactionJSON,
        transactionStatus,
        setTransactionStatus,
    };

    return (
        <SendTransactionContext.Provider value={value}>
            {children}
        </SendTransactionContext.Provider>
    );
};

export const useSendTransaction = (): SendTransactionContextValue => {
    const context = useContext(SendTransactionContext);
    if (!context) {
        throw new Error('useSendTransaction must be used within SendTransactionProvider');
    }
    return context;
};
