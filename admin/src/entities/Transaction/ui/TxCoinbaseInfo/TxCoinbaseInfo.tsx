import { SwapOutlined } from '@ant-design/icons';

import { brand } from '@/brand';
import { formatNumber } from '@/shared/utils';
import { satToNativeString } from '@/shared/lib/fmtbtc';
import { useNetwork } from '@/shared/lib/network';

import type { CoinbaseInfo } from '../../lib/txType';
import { powExplorerTxUrl, powTxid } from '../../lib/powTxid';
import { TxInfoPanel, type TxInfoRow } from '../TxInfoPanel/TxInfoPanel.tsx';

interface TxCoinbaseInfoProps {
    className?: string;
    info: CoinbaseInfo;
}

export const TxCoinbaseInfo = ({ className, info }: TxCoinbaseInfoProps) => {
    const network = useNetwork();
    const txid = powTxid(info.tx_hash);
    const url = powExplorerTxUrl(brand.powChain?.explorerTxUrl[network], txid);
    const label = brand.powChain?.label;
    const shown = txid || info.tx_hash;

    const rows: TxInfoRow[] = [
        {
            label: 'Source transaction',
            value: url
                ? <a href={url} target="_blank" rel="noreferrer">{shown} <span aria-hidden="true">↗</span></a>
                : shown,
        },
        {
            label: 'Origin',
            value: `Output ${info.out_num} · Block ${formatNumber(info.block_height)}`,
        },
        {
            label: 'Converted amount',
            value: `${formatNumber(satToNativeString(info.value), 8)}${label ? ` ${label}` : ''}`,
        },
    ];

    return (
        <TxInfoPanel
            className={className}
            title="Source-chain conversion"
            description="This value entered the network from a confirmed proof-of-work output."
            icon={<SwapOutlined />}
            rows={rows}
        />
    );
};
