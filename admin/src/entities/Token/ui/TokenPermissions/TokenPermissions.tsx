import { Link } from 'react-router-dom';

import { useGetTokenInfoQuery } from '../../api/tokenApi.ts';
import { tokenLabels } from '../../lib/tokenLabels.ts';

interface TokenPermissionsProps {
    tokenId: string;
    permissions: number | string;
    className?: string;
}

export const TokenPermissions = ({ tokenId, permissions, className }: TokenPermissionsProps) => {
    const { data } = useGetTokenInfoQuery({ tokenId });
    const label = tokenLabels(data).ticker || `${tokenId.slice(0, 4)}…`;

    return (
        <span className={className} style={{ textTransform: 'none' }}>
            Token permissions{' '}
            <span translate="no">{permissions}</span>{' '}
            <Link to={`/token/${tokenId}`} translate="no">{label}</Link>
        </span>
    );
};
