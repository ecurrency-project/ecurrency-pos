import { WarningOutlined } from '@ant-design/icons';

import { formatSat } from '@/shared/utils';
import { useAssetLabel } from '@/shared/lib/network';
import type { BaseUnits } from '@/shared/lib/baseUnits';

import { TxInfoPanel } from '../TxInfoPanel/TxInfoPanel.tsx';

interface TxSlashingInfoProps {
    className?: string;
    fine: BaseUnits;
    inputCount: number;
    outputCount: number;
}

export const TxSlashingInfo = ({ className, fine, inputCount, outputCount }: TxSlashingInfoProps) => {
    const assetLabel = useAssetLabel();

    return (
        <TxInfoPanel
            className={className}
            title="Validator equivocation penalty"
            description="The protocol spends the conflicting stake outputs without signatures and returns the remainder to their owners."
            icon={<WarningOutlined />}
            rows={[
                { label: 'Penalty', value: formatSat(fine, assetLabel) },
                { label: 'Affected inputs', value: `${inputCount} · protocol-authorized` },
                { label: 'Returned through', value: `${outputCount} ${outputCount === 1 ? 'output' : 'outputs'}` },
            ]}
        />
    );
};
