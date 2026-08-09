export interface IStakingKey {
    /** base58 hash256 of the staking pubkey; what the delegate publishes for the owners */
    pubkeyhash: string;
    algo: string;
    /** Number of delegated addresses on this key */
    delegations: number;
}

export interface IDelegation {
    address: string;
    owner_pubkeyhash: string;
    staking_pubkeyhash: string;
}

export interface AddDelegationParams {
    owner_pubkeyhash: string;
    /** Required only when the wallet has more than one staking key */
    staking_pubkeyhash?: string;
}

export interface NewStakingKeyResult {
    pubkeyhash: string;
    warning?: string;
}
