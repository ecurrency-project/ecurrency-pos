export interface ITokenInfo {
    token_id: string;
    decimals: number;
    issuer: string;
    name?: string;
    symbol?: string;
    create_time?: number;
    total_supply?: number;
    mint_allowed?: boolean;
}

export type TokenTransfer = [txid: string, amount: number, height: number];
