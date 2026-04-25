import { Skeleton } from 'antd';

import { formatSat } from '@/shared/utils';
import { BALANCE_POLL_INTERVAL } from '@/shared/const/const.ts';

import { useGetAddressQuery } from '../../api/addressApi';

interface AddressBalanceProps {
    address: string;
}

export const AddressBalance = ({ address }: AddressBalanceProps) => {
    const { data, isLoading } = useGetAddressQuery({ id: address }, {
        pollingInterval: BALANCE_POLL_INTERVAL,
    });

    if (isLoading) {
        return <Skeleton.Input active size="small" style={{ width: 120, minWidth: 120 }} />;
    }

    if (!data) {
        return <span>—</span>;
    }

    const balance = data.chain_stats.funded_txo_sum - data.chain_stats.spent_txo_sum;

    return <span>{formatSat(balance)}</span>;
};
