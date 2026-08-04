export interface TransactionInput {
    txid: string;
    vout: number;
}

/**
 * Output object for POST /wallet/transaction/create: `{"<addr>": "<sat>"}` for
 * native. A token output additionally carries `token_id` and `token_amount`
 * (base units) and holds exactly one address key. Every amount is a decimal
 * string — see toWireAmount.
 */
export type TransactionOutput = Record<string, string>;

export interface TransactionJSON {
    inputs: TransactionInput[];
    outputs: TransactionOutput[];
}

export type TransactionStatus = 'process' | 'finish' | 'error';

export interface SendTransactionFormState {
    targetAddress: string;
    amountSat: bigint;
    selectedAddresses: string[];
    feeRate: number;
    changeAddress: string;
    transactionJSON?: TransactionJSON;
    transactionStatus: TransactionStatus;
}

export interface SendTransactionFormActions {
    setTargetAddress: (value: string) => void;
    setAmountSat: (value: bigint) => void;
    setSelectedAddresses: (value: string[]) => void;
    setFeeRate: (value: number) => void;
    setChangeAddress: (value: string) => void;
    setTransactionStatus: (value: TransactionStatus) => void;
}

export type CreateTransactionRequest = TransactionJSON;

export interface CreateTransactionResponse {
    hex: string;
    hash: string;
    fee: number;
}

export interface SendTransactionRequest {
    hex: string;
}
