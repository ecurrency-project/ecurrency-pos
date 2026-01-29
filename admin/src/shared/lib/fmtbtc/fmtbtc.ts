import { moveDecimalPoint } from '@/shared/lib/moveDecimalPoint';

export type Unit = 'msat' | 'sat' | 'bit' | 'milli' | 'btc';

export const units: Record<Unit, number> = {
    msat: 1,
    sat: 4,
    bit: 6,
    milli: 9,
    btc: 12,
};

const commaRegex = /\B(?=(\d{3})+(?!\d))/g;

/**
 * Adds commas to an integer string for thousands separators
 */
function addCommas(s: string): string {
    return s.replace(commaRegex, ',');
}

/**
 * Convert a value between units without formatting
 * @param n Value to convert (number or numeric string)
 * @param from Source unit
 * @param to Target unit
 * @returns Converted numeric string
 */
export function fmt(
    n: number | string,
    from: Unit,
    to: Unit
): string {
    return moveDecimalPoint(n, units[from] - units[to]);
}

/**
 * Convert a value between units with thousands separators in the integer part
 * @param n Value to convert (number or numeric string)
 * @param from Source unit
 * @param to Target unit
 * @returns Formatted converted string
 */
export function pfmt(
    n: number | string,
    from: Unit,
    to: Unit
): string {
    const result = fmt(n, from, to);
    return result
        .split('.')
        .map((part, idx) => (idx === 0 ? addCommas(part) : part))
        .join('.');
}

/**
 * Dynamically generated converters for all unit pairs, keyed by `${from}2${to}`
 */
export type ConversionFn = (
    n: number | string,
    pretty?: boolean
) => number;

export const converters: Record<`${Unit}2${Unit}`, ConversionFn> = {} as never;

(Object.keys(units) as Unit[]).forEach((from) => {
    (Object.keys(units) as Unit[]).forEach((to) => {
        if (from !== to) {
            const key = `${from}2${to}` as `${Unit}2${Unit}`;
            converters[key] = (n, pretty = false) =>
                pretty ? +pfmt(n, from, to) : +fmt(n, from, to);
        }
    });
});
