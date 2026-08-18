import { Link } from 'react-router-dom';
import { FireOutlined, SwapOutlined } from '@ant-design/icons';

import { brand } from '@/brand';
import { formatNumber } from '@/shared/utils';
import { satToNativeString } from '@/shared/lib/fmtbtc';
import { useNetwork } from '@/shared/lib/network';

import type { BurnInfo, DowngradeInfo } from '../../lib/txType';
import { isDowngradeInfo } from '../../lib/txType';
import { powExplorerTxUrl } from '../../lib/powTxid';
import { TxInfoPanel, type TxInfoRow } from '../TxInfoPanel/TxInfoPanel.tsx';

interface TxDowngradeInfoProps {
    className?: string;
    info: DowngradeInfo | BurnInfo;
}

export const TxDowngradeInfo = ({ className, info }: TxDowngradeInfoProps) => {
    const network = useNetwork();
    const label = brand.powChain?.label;
    // Unlike a coinbase hash, this one arrives already in display byte order.
    const url = powExplorerTxUrl(brand.powChain?.explorerTxUrl[network], info.btc_txid);
    const target = url
        ? <a href={url} target="_blank" rel="noreferrer">{info.btc_txid} <span aria-hidden="true">↗</span></a>
        : info.btc_txid;

    const rows: TxInfoRow[] = isDowngradeInfo(info)
        ? [
            { label: 'Target transaction', value: target },
            {
                label: 'Target output',
                value: `#${info.btc_vout} · ${formatNumber(satToNativeString(info.btc_value), 8)}${label ? ` ${label}` : ''}`,
            },
            {
                label: 'Frozen output',
                value: <Link to={`/tx/${info.freeze_txid}`}>{`${info.freeze_txid}:${info.freeze_vout}`}</Link>,
            },
            { label: 'Target script', value: info.btc_scriptpubkey },
        ]
        : [
            { label: 'Target transaction', value: target },
            { label: 'Target block', value: info.btc_block_hash },
        ];

    return (
        <TxInfoPanel
            className={className}
            title={isDowngradeInfo(info) ? 'Target-chain conversion' : 'Conversion completed by burn'}
            description={isDowngradeInfo(info)
                ? 'This output is locked here while the linked value becomes spendable on the proof-of-work chain.'
                : 'The locked source output was permanently consumed after its proof-of-work transaction was confirmed.'}
            icon={isDowngradeInfo(info) ? <SwapOutlined /> : <FireOutlined />}
            rows={rows}
        />
    );
};
