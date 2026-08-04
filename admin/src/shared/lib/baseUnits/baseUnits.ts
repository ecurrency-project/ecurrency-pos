/**
 * A base-unit amount from the node may arrive as a JSON number or as a decimal
 * string: values are read straight out of the DB, and a Perl scalar holding both
 * an integer and a string representation may be encoded either way. A string is
 * also the only lossless encoding for amounts above 2^53.
 *
 * Returns null for anything that is not a whole base-unit value, so a caller can
 * skip it instead of silently miscounting.
 */
export const toBaseUnits = (value: unknown): bigint | null => {
    if (typeof value === 'number') {
        return Number.isInteger(value) ? BigInt(value) : null;
    }
    if (typeof value === 'string' && /^\d+$/.test(value.trim())) {
        return BigInt(value.trim());
    }
    return null;
};
