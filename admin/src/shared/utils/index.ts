import { nativeAssetLabel } from '@/shared/const/const.ts';
import { sat2btc } from '@/shared/lib/fmtbtc';

const NATIVE_PRECISION = 8;
const HASH256_RE = /^[a-f0-9]{64}$/i;
const NUMBER_RE = /^\d+$/;
// const ADDRESS_RE = /^([a-km-zA-HJ-NP-Z1-9]{26,35}|[a-km-zA-HJ-NP-Z1-9]{80}|[a-z]{2,5}1[ac-hj-np-z02-9]{8,100}|[A-Z]{2,5}1[AC-HJ-NP-Z02-9]{8,100})$/;
const ADDRESS_RE = /^(?:EC[1-9A-HJ-NP-Za-km-z]{33}|26[k-n][1-9A-HJ-NP-Za-km-z]{49})$/;
const ADDRESS_TEST_RE = /^(?:Et[1-9A-HJ-NP-Za-km-z]{33}|2A[678][1-9A-HJ-NP-Za-km-z]{49})$/;
export const SHORT_TX_OUT_RE = /^(\d+)([x:])(\d+)\2(\d+)$/;

const combinePatterns = (...patterns: RegExp[]) => {
    const combinedPattern = patterns.map(pattern => pattern.source.slice(1, -1)).join('|');
    return new RegExp(`^(${combinedPattern})$`);
};

const COMBINED_ADDRESS_RE = combinePatterns(ADDRESS_RE, ADDRESS_TEST_RE);

const pad = (n: number): string => n < 10 ? '0' + n : n.toString();

export const isHash256 = (str: string) => HASH256_RE.test(str);
export const isNumber = (str: string) => NUMBER_RE.test(str);
export const isAddress = (str: string) => COMBINED_ADDRESS_RE.test(str);
export const isShortTxOut = (str: string) => SHORT_TX_OUT_RE.test(str);

export const formatTime = (unix: number, useUTC: boolean = false) => {
    const time = new Date(unix * 1000)

    const year = useUTC ? time.getUTCFullYear() : time.getFullYear()
    const month = useUTC ? time.getUTCMonth() : time.getMonth()
    const date = useUTC ? time.getUTCDate() : time.getDate()
    const hours = useUTC ? time.getUTCHours() : time.getHours()
    const minutes = useUTC ? time.getUTCMinutes() : time.getMinutes()
    const seconds = useUTC ? time.getUTCSeconds() : time.getSeconds()

    return `${year}-${pad(month + 1)}-${pad(date)}`
        + ` ${pad(hours)}:${pad(minutes)}:${pad(seconds)}`
        + (useUTC ? ' UTC' : '')
}

export const formatNumber = (s: number, precision: number | null = null): string => {
    // eslint-disable-next-line prefer-const
    let [whole, dec] = s.toString().split('.');

    // divide numbers into groups of three separated with a thin space (U+202F, "NARROW NO-BREAK SPACE"),
    // but only when there are more than a total of 5 non-decimal digits.
    // if (whole.length >= 5) {
    //   whole = whole.replace(/\B(?=(\d{3})+(?!\d))/g, "\u202F")
    // }

    if (precision != null && precision > 0) {
        if (dec == null) dec = '0'.repeat(precision)
        else if (dec.length < precision) dec += '0'.repeat(precision - dec.length)
    }

    return whole + (dec != null ? '.' + dec : '')
}

export const formatSat = (sats: number, label = nativeAssetLabel): string => `${formatNumber(sat2btc(sats), NATIVE_PRECISION)} ${label}`
