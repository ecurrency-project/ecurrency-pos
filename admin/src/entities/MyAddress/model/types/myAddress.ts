export interface IMyAddress {
    address: string;
    staked: number;
}

export interface AddAddressParams {
    address: string;
    private_key: string;
}

export interface EditStakedParams {
    address: string;
    staked: number;
}
