import { moveDecimalPoint } from '@/shared/lib/moveDecimalPoint';

export const formatTokenAmount = (amount: number | string, decimals: number): string => {
    const shifted = moveDecimalPoint(amount, -decimals);
    const negative = shifted.startsWith('-');
    const [intPart, fracPart] = (negative ? shifted.slice(1) : shifted).split('.');
    const grouped = intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return `${negative ? '-' : ''}${grouped}${fracPart ? `.${fracPart}` : ''}`;
};
