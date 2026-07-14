import { createContext, type FC, type ReactNode, useCallback, useContext, useMemo, useState } from 'react';
import { useLocation } from 'react-router-dom';

import { useGetFeeEstimateQuery } from '@/entities/Transaction';
import { useGetTokenInfoQuery, tokenLabels } from '@/entities/Token';

import type { TransactionJSON, TransactionStatus } from '../types/types';
import { useWalletUtxoData } from '../../lib/useWalletUtxoData';
import type { SpendableUtxo, TokenUtxoGroup } from '../../lib/processUtxos';
import { getDefaultFeeRate, suggestFeeSat, suggestTokenFeeSat } from '../../lib/feeEstimation';
import { createTransactionJSON as buildTransaction, type CreateTransactionJSONResult } from '../../lib/createTransactionJSON';
import { createTokenTransactionJSON as buildTokenTransaction } from '../../lib/createTokenTransactionJSON';
import { parseTokenAmount } from '../../lib/tokenAmount';

export interface AddressData {
    balance: number;
    balanceFormatted: string;
    utxos: SpendableUtxo[];
    tokens: Record<string, TokenUtxoGroup>;
}

/** The native coin sentinel for the Asset field; any other value is a token id. */
export const NATIVE_ASSET_ID = 'native';

const DEFAULT_TOKEN_DECIMALS = 6;

interface SendTransactionContextValue {
    step: number;
    next: () => void;
    prev: () => void;

    targetAddress: string;
    setTargetAddress: (value: string) => void;
    amountSat: number;
    setAmountSat: (value: number) => void;
    /** Token amount as the raw decimal input string (base-unit precision > 2^53). */
    tokenAmount: string;
    setTokenAmount: (value: string) => void;
    selectedAddresses: string[];
    setSelectedAddresses: (value: string[]) => void;
    feeSat: number;
    suggestedFeeSat: number;
    isFeeManual: boolean;
    setFeeSat: (value: number | null) => void;
    changeAddress: string;
    setChangeAddress: (value: string) => void;

    /** NATIVE_ASSET_ID or a token id. */
    assetId: string;
    setAssetId: (value: string) => void;
    isTokenMode: boolean;
    tokenTicker: string;
    tokenDecimals: number;
    /** Selected token balance (base units) across the selected source addresses. */
    selectedTokenBalance: bigint;
    /** Per-token totals (base units) across all wallet addresses — for the Asset field. */
    tokenTotals: Record<string, bigint>;

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
    const location = useLocation();
    // "Send" / "Send <TICKER>" entries from the wallet cards pre-fill the wizard.
    const navState = (location.state ?? {}) as { address?: string; tokenId?: string };

    const [step, setStep] = useState(0);

    const [transactionStatus, setTransactionStatus] = useState<TransactionStatus>('process');
    const [targetAddress, setTargetAddress] = useState('');
    const [amountSat, setAmountSat] = useState(0);
    const [tokenAmount, setTokenAmount] = useState('');
    const [selectedAddresses, setSelectedAddresses] = useState<string[]>(
        navState.address ? [navState.address] : []
    );
    const [manualFeeSat, setManualFeeSat] = useState<number | null>(null);
    const [changeAddress, setChangeAddress] = useState('');
    const [transactionJSON, setTransactionJSON] = useState<TransactionJSON | undefined>();
    const [assetId, setAssetIdState] = useState<string>(navState.tokenId ?? NATIVE_ASSET_ID);

    // Any token the wallet holds is supported — no feature gate.
    const isTokenMode = assetId !== NATIVE_ASSET_ID;

    const { addressesData, isLoading: isUtxoLoading, isError: isUtxoError } = useWalletUtxoData();
    const { data: feeEstimate } = useGetFeeEstimateQuery(undefined, {
        pollingInterval: 60_000,
    });
    const { data: tokenInfo } = useGetTokenInfoQuery(
        { tokenId: assetId },
        { skip: !isTokenMode }
    );

    const tokenDecimals = tokenInfo?.decimals ?? DEFAULT_TOKEN_DECIMALS;
    const tokenTicker = tokenLabels(tokenInfo).ticker || (isTokenMode ? `${assetId.slice(0, 4)}…` : '');

    const tokenTotals = useMemo(() => {
        const totals: Record<string, bigint> = {};
        Object.values(addressesData ?? {}).forEach((data) => {
            Object.entries(data.tokens ?? {}).forEach(([id, group]) => {
                totals[id] = (totals[id] ?? 0n) + group.amount;
            });
        });
        return totals;
    }, [addressesData]);

    const selectedTokenBalance = useMemo(() => {
        if (!isTokenMode) return 0n;
        return selectedAddresses.reduce(
            (sum, address) => sum + (addressesData?.[address]?.tokens?.[assetId]?.amount ?? 0n),
            0n
        );
    }, [isTokenMode, selectedAddresses, addressesData, assetId]);

    const feeRate = useMemo(() => getDefaultFeeRate(feeEstimate) ?? 0, [feeEstimate]);

    const suggestedFeeSat = useMemo(() => {
        if (feeRate <= 0 || !addressesData) return 0;

        if (isTokenMode) {
            const tokenUtxos = selectedAddresses.flatMap(
                (address) => addressesData[address]?.tokens?.[assetId]?.utxos ?? []
            );
            if (tokenUtxos.length === 0) return 0;

            const nativeUtxos = selectedAddresses.flatMap(
                (address) => addressesData[address]?.utxos ?? []
            );
            const parsed = parseTokenAmount(tokenAmount || '', tokenDecimals);

            return suggestTokenFeeSat({
                tokenUtxos,
                nativeUtxos,
                tokenAmount: parsed.ok ? parsed.value : 0n,
                feeRate,
            });
        }

        const availableUtxos = selectedAddresses.flatMap(
            (address) => addressesData[address]?.utxos ?? []
        );
        if (availableUtxos.length === 0) return 0;

        return suggestFeeSat({ utxos: availableUtxos, amountSat, feeRate });
    }, [feeRate, addressesData, selectedAddresses, amountSat, isTokenMode, assetId, tokenAmount, tokenDecimals]);

    const feeSat = manualFeeSat ?? suggestedFeeSat;

    const handleSetFeeSat = useCallback((value: number | null) => {
        setManualFeeSat(value);
    }, []);

    // Switching the asset changes the amount's unit — reset both amounts.
    const setAssetId = useCallback((value: string) => {
        setAssetIdState(value);
        setAmountSat(0);
        setTokenAmount('');
    }, []);

    const next = useCallback(() => {
        setStep((s) => s + 1);
    }, []);

    const prev = useCallback(() => {
        setStep((s) => s - 1);
    }, []);

    const createTransactionJSON = useCallback((): CreateTransactionJSONResult => {
        if (isTokenMode) {
            const parsed = parseTokenAmount(tokenAmount || '', tokenDecimals);
            if (!parsed.ok) {
                return {
                    success: false,
                    error: parsed.error === 'too_many_decimals'
                        ? 'Too many decimal places'
                        : 'Invalid amount',
                };
            }

            const result = buildTokenTransaction({
                tokenId: assetId,
                tokenAmount: parsed.value,
                targetAddress,
                changeAddress,
                selectedAddresses,
                feeSat,
                addressesData,
            });

            if (result.success) {
                setTransactionJSON(result.data);
            }

            return result;
        }

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
    }, [isTokenMode, assetId, tokenAmount, tokenDecimals, targetAddress, amountSat, feeSat, selectedAddresses, changeAddress, addressesData]);

    const value: SendTransactionContextValue = {
        step,
        next,
        prev,
        targetAddress,
        setTargetAddress,
        amountSat,
        setAmountSat,
        tokenAmount,
        setTokenAmount,
        selectedAddresses,
        setSelectedAddresses,
        feeSat,
        suggestedFeeSat,
        isFeeManual: manualFeeSat != null,
        setFeeSat: handleSetFeeSat,
        changeAddress,
        setChangeAddress,
        assetId,
        setAssetId,
        isTokenMode,
        tokenTicker,
        tokenDecimals,
        selectedTokenBalance,
        tokenTotals,
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
