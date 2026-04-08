import { useEffect, useState } from 'react';

import { useGetMyAddressesQuery } from '@/entities/MyAddress';
import { useLazyGetAddressUtxosQuery } from '@/entities/Address';

import { formatSat } from '@/shared/utils';

import type { AddressData } from '../model/context/SendTransactionContext';
import { processUtxos } from './processUtxos';

interface UseWalletUtxoDataResult {
    addressesData?: Record<string, AddressData>;
    isLoading: boolean;
    isError: boolean;
}

export const useWalletUtxoData = (): UseWalletUtxoDataResult => {
    const [addressesData, setAddressesData] = useState<Record<string, AddressData>>();
    const [isLoading, setIsLoading] = useState(false);
    const [isError, setIsError] = useState(false);

    const { data: walletsData } = useGetMyAddressesQuery();
    const [fetchUtxos] = useLazyGetAddressUtxosQuery();

    useEffect(() => {
        if (!walletsData?.length) return;

        const addresses = walletsData.map(({ address }) => address);

        setIsLoading(true);
        setIsError(false);

        Promise.all(
            addresses.map((address) =>
                fetchUtxos(address)
                    .unwrap()
                    .then((utxos) => ({ address, utxos }))
                    .catch(() => ({ address, utxos: [] as never[] }))
            )
        )
            .then((results) => {
                const map: Record<string, AddressData> = {};

                results.forEach(({ address, utxos }) => {
                    const { value, utxos: utxoStrings } = processUtxos(utxos);

                    map[address] = {
                        balance: value,
                        balanceFormatted: formatSat(value),
                        utxos: utxoStrings,
                    };
                });

                setAddressesData(map);
            })
            .finally(() => {
                setIsLoading(false);
            });
    }, [walletsData, fetchUtxos]);

    return { addressesData, isLoading, isError };
};
