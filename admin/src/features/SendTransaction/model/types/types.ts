export interface TransactionInput {
    txid: string;
    vout: number;
}

export interface TransactionJSON {
    inputs: TransactionInput[];
    outputs: Record<string, number>[];
}

export type TransactionStatus = 'process' | 'finish' | 'error';

export interface SendTransactionFormState {
    targetAddress: string;
    amountSat: number;
    selectedAddresses: string[];
    feeRate: number;
    changeAddress: string;
    transactionJSON?: TransactionJSON;
    transactionStatus: TransactionStatus;
}

export interface SendTransactionFormActions {
    setTargetAddress: (value: string) => void;
    setAmountSat: (value: number) => void;
    setSelectedAddresses: (value: string[]) => void;
    setFeeRate: (value: number) => void;
    setChangeAddress: (value: string) => void;
    setTransactionStatus: (value: TransactionStatus) => void;
}

export interface CreateTransactionRequest extends TransactionJSON {}

export interface CreateTransactionResponse {
    hex: string;
    hash: string;
    fee: number;
}

export interface SendTransactionRequest {
    hex: string;
}
