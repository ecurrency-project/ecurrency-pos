const HEX_HASH_RE = /^(?:[0-9a-f]{2})+$/i;

export const powTxid = (internalHex: string): string => {
    if (!HEX_HASH_RE.test(internalHex)) return '';
    const hex = internalHex.toLowerCase();
    let out = '';
    for (let i = hex.length - 2; i >= 0; i -= 2) {
        out += hex.slice(i, i + 2);
    }
    return out;
};

export const powExplorerTxUrl = (base: string | undefined, txid: string): string | undefined =>
    base && txid ? `${base}${txid}` : undefined;
