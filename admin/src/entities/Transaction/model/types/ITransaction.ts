import type { EntityState } from '@reduxjs/toolkit';

export interface Prevout {
    scripthash_address: string;
    scripthash: string;
    value: number;
    asset?: string;
    assetcommitment?: string;
    scriptpubkey_type?: string;
    token_amount?: number;
    token_permissions?: number;
    token_decimals?: number;
    token_id?: string;
}

export interface Issuance {
    asset_id: string;
    asset_commitment: string;
    token_amount: number;
    token_commitment: string;
    asset_blinding_nonce: string;
    asset_entropy: string;
    contract_hash: string;
    isreissuance: boolean;
    inflation_keys?: string[];
    is_reissuance: boolean;
    tokenamountcommitment?: string;
    tokenamount?: number;
}

export interface Vin {
    txid: string;
    vout: number;
    scriptsig: string;
    scriptsig_asm: string;
    witness: string[];
    is_coinbase: boolean;
    sequence: number;
    inner_redeemscript_asm?: string;
    inner_witnessscript_asm?: string;
    is_pegin?: boolean;
    prevout?: Prevout;
    redeem_script?: string;
    siglist?: string[];
    issuance?: Issuance;
}

export interface Scriptpubkey {
    asm: string;
    hex: string;
    type: string;
    req_sigs?: number;
    addresses?: string[];
}

interface Pegout {
    genesis_hash: string;
    scriptpubkey: string;
    scripthash_address: string;
}

export interface Vout {
    scripthash: string;
    scriptpubkey: string;
    scriptpubkey_type: string;
    scripthash_address?: string;
    value: number;
    valuecommitment: string;
    asset: string;
    assetcommitment: string;
    pegout?: Pegout;
    token_id: string;
    token_amount: number;
    token_permissions: number;
    token_decimals: number;
}

export interface ITxStatus {
    confirmed: boolean;
    block_height: number;
    block_hash: string;
    block_time: number;
}

export interface ITransaction {
    txid: string;
    version: number;
    locktime: number;
    vin: Vin[];
    vout: Vout[];
    size: number;
    weight: number;
    fee: number;
    value: number;
    is_coinbase: boolean;
    status: ITxStatus;
    token_id?: string;
}

export interface TxShort {
    txid: string;
    fee: number;
    size: number;
    value: number;
}

export interface ITransactionBoxSchema extends EntityState<ITransaction, string>{
    isLoading: boolean;
    error?: string | undefined;
}

export interface ISpend {
    spent: boolean;
    txid?: string;
    vin?: number;
    status?: ITxStatus;
}
