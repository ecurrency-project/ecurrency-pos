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

/**
 * Transfer amount is uint64 in the node. Today the node serializes it as a
 * JSON number, so values above 2^53−1 lose precision at JSON.parse — fixing
 * that requires the node to send a decimal string (see the port plan, §6).
 * The type and the UI already accept strings so the switch is frontend-ready.
 */
export type TokenTransfer = [txid: string, amount: number | string, height: number];
