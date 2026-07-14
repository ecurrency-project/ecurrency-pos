export type ParseTokenAmountResult =
    | { ok: true; value: bigint }
    | { ok: false; error: 'invalid' | 'not_positive' | 'too_many_decimals' };

/**
 * Parse a user-entered decimal amount into token base units (BigInt).
 * No floats anywhere: token amounts may exceed 2^53 (up to 18 digits),
 * so the string is split and scaled textually.
 */
export const parseTokenAmount = (input: string, decimals: number): ParseTokenAmountResult => {
    const trimmed = input.trim();

    if (!/^\d+(\.\d+)?$/.test(trimmed)) {
        return { ok: false, error: 'invalid' };
    }

    const [intPart, fracPart = ''] = trimmed.split('.');

    if (fracPart.length > decimals) {
        return { ok: false, error: 'too_many_decimals' };
    }

    const value = BigInt(intPart) * 10n ** BigInt(decimals) + BigInt(fracPart.padEnd(decimals, '0') || '0');

    if (value <= 0n) {
        return { ok: false, error: 'not_positive' };
    }

    return { ok: true, value };
};
