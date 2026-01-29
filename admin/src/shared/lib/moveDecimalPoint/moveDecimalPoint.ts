export function moveDecimalPoint(
    num: number | string,
    shift: number
): string {
    let [intPart, fracPart = ""] = String(num).split('.');
    const neg = intPart.startsWith('-') ? '-' : '';
    if (neg) intPart = intPart.slice(1);

    if (shift > 0) {
        // Shift right: append zeros if needed
        if (shift > fracPart.length) {
            fracPart = fracPart.padEnd(shift, '0');
        }
        intPart = intPart + fracPart.slice(0, shift);
        fracPart = fracPart.slice(shift);
    } else if (shift < 0) {
        // Shift left: pad intPart on left if needed
        const absShift = -shift;
        if (absShift > intPart.length) {
            intPart = intPart.padStart(absShift + intPart.length, '0');
        }
        fracPart = intPart.slice(-absShift) + fracPart;
        intPart = intPart.slice(0, -absShift) || '0';
    }

    // Trim leading zeros in intPart and trailing zeros in fracPart
    intPart = intPart.replace(/^0+(?!$)/, '');
    fracPart = fracPart.replace(/0+$/, '');

    return `${neg}${intPart}${fracPart ? `.${fracPart}` : ''}`;
}
