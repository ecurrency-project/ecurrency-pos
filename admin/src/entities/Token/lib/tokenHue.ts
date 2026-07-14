/**
 * Deterministic hue (0..359) for a token monogram tile.
 * Same hash as the approved cabinet design:
 * h = h * 31 + charCode, unsigned 32-bit, mod 360.
 */
export const tokenHue = (seed: string): number => {
    let h = 0;
    for (let i = 0; i < seed.length; i++) {
        h = (h * 31 + seed.charCodeAt(i)) >>> 0;
    }
    return h % 360;
};
