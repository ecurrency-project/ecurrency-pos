import { createContext, type FC, type ReactNode, useCallback, useContext, useMemo, useState } from 'react';

import { useGetFeeEstimateQuery } from '@/entities/Transaction';

import type { TransactionJSON, TransactionStatus } from '../types/types';
import { useWalletUtxoData } from '../../lib/useWalletUtxoData';
import type { SpendableUtxo } from '../../lib/processUtxos';
import { getDefaultFeeRate, suggestFeeSat } from '../../lib/feeEstimation';
import { createTransactionJSON as buildTransaction, type CreateTransactionJSONResult } from '../../lib/createTransactionJSON';

export interface AddressData {
    balance: number;
    balanceFormatted: string;
    utxos: SpendableUtxo[];
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
    feeSat: number;
    suggestedFeeSat: number;
    isFeeManual: boolean;
    setFeeSat: (value: number | null) => void;
    changeAddress: string;
    setChangeAddress: (value: string) => void;

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
    const [manualFeeSat, setManualFeeSat] = useState<number | null>(null);
    const [changeAddress, setChangeAddress] = useState('');
    const [transactionJSON, setTransactionJSON] = useState<TransactionJSON | undefined>();

    const { addressesData, isLoading: isUtxoLoading, isError: isUtxoError } = useWalletUtxoData();
    const { data: feeEstimate } = useGetFeeEstimateQuery(undefined, {
        pollingInterval: 60_000,
    });

    const feeRate = useMemo(() => getDefaultFeeRate(feeEstimate) ?? 0, [feeEstimate]);

    const suggestedFeeSat = useMemo(() => {
        if (feeRate <= 0 || !addressesData) return 0;

        const availableUtxos = selectedAddresses.flatMap(
            (address) => addressesData[address]?.utxos ?? []
        );
        if (availableUtxos.length === 0) return 0;

        return suggestFeeSat({ utxos: availableUtxos, amountSat, feeRate });
    }, [feeRate, addressesData, selectedAddresses, amountSat]);

    const feeSat = manualFeeSat ?? suggestedFeeSat;

    const handleSetFeeSat = useCallback((value: number | null) => {
        setManualFeeSat(value);
    }, []);

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
        feeSat,
        suggestedFeeSat,
        isFeeManual: manualFeeSat != null,
        setFeeSat: handleSetFeeSat,
        changeAddress,
        setChangeAddress,
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
