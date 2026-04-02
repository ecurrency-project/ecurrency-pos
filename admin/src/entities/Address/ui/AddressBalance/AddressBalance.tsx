import { Skeleton } from 'antd';

import { formatSat } from '@/shared/utils';

import { useGetAddressQuery } from '../../api/addressApi';

interface AddressBalanceProps {
    address: string;
}

export const AddressBalance = ({ address }: AddressBalanceProps) => {
    const { data, isLoading } = useGetAddressQuery({ id: address });

    if (isLoading) {
        return <Skeleton.Input active size="small" style={{ width: 120, minWidth: 120 }} />;
    }

    if (!data) {
        return <span>—</span>;
    }

    const balance = data.chain_stats.funded_txo_sum - data.chain_stats.spent_txo_sum;

    return <span>{formatSat(balance)}</span>;
};
