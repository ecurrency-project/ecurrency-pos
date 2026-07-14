interface TokenLike {
    name?: string;
    symbol?: string;
}

interface TokenLabels {
    ticker: string;
    name: string;
}

export const tokenLabels = (token?: TokenLike): TokenLabels => {
    const symbol = token?.symbol?.trim() ?? '';
    const name = token?.name?.trim() ?? '';
    const both = [symbol, name].filter(Boolean);

    if (both.length === 0) return { ticker: '', name: '' };
    if (both.length === 1) return { ticker: both[0], name: '' };

    const [ticker, fullName] = symbol.length <= name.length ? [symbol, name] : [name, symbol];
    return { ticker, name: ticker === fullName ? '' : fullName };
};
