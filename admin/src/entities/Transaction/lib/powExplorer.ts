const HASH_RE = /^[0-9a-f]{64}$/i;

export const powExplorerUrl = (
    base: string | undefined,
    page: 'tx' | 'block',
    hash: string,
): string | undefined =>
    base && HASH_RE.test(hash) ? `${base.replace(/\/+$/, '')}/${page}/${hash}` : undefined;
