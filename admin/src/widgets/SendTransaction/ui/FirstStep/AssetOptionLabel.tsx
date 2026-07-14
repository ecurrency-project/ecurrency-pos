import { useGetTokenInfoQuery, tokenLabels, formatTokenAmount } from '@/entities/Token';

interface AssetOptionLabelProps {
    tokenId: string;
    /** Total balance across all wallet addresses, base units. */
    total: bigint;
}

/** Label for a token entry in the Asset select: "TICKER — total balance". */
export const AssetOptionLabel = ({ tokenId, total }: AssetOptionLabelProps) => {
    const { data } = useGetTokenInfoQuery({ tokenId });

    const { ticker } = tokenLabels(data);
    const label = ticker || `${tokenId.slice(0, 8)}…`;

    return (
        <span translate="no">
            {label} — {formatTokenAmount(total.toString(), data?.decimals ?? 0)}
        </span>
    );
};
