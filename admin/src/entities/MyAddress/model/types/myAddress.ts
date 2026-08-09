export interface IMyAddress {
    address: string;
    staked: boolean | number;
    /** Delegated-staking role of the wallet for this address */
    delegation?: 'owner' | 'both';
}

export interface AddAddressParams {
    address: string;
    private_key: string;
}

export interface GenerateAddressParams {
    /** Staking pubkeyhash published by a delegate: generates a delegated-staking address */
    delegate_pubkeyhash?: string;
}

export interface GeneratedAddress {
    address: string;
    private_key: string;
    /** Owner pubkeyhash to send to the delegate (delegated-staking addresses only) */
    pubkeyhash?: string;
}

export interface EditStakedParams {
    address: string;
    staked: number;
}
