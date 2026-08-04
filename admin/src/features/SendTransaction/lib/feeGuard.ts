export type FeeRisk = 'ok' | 'warn' | 'block';

export interface FeeAssessment {
    level: FeeRisk;
    message?: string;
    percent?: number;
}

const WARN_PERCENT = 10n;

export const assessFee = (amountSat: bigint, feeSat: bigint): FeeAssessment => {
    if (amountSat <= 0n || feeSat <= 0n) return { level: 'ok' };

    if (feeSat >= amountSat) {
        return {
            level: 'block',
            message: "The fee is higher than the amount you're sending. Lower the fee or raise the amount.",
        };
    }

    if (feeSat * 100n >= amountSat * WARN_PERCENT) {
        // BigInt division truncates toward zero, which for positive operands is
        // exactly the Math.floor this used to do.
        const percent = Number((feeSat * 100n) / amountSat);
        return {
            level: 'warn',
            percent,
            message: `Heads up — the fee is about ${percent}% of the amount you're sending.`,
        };
    }

    return { level: 'ok' };
};

// Token sends: the amount is in a different unit, so percentage thresholds are
// meaningless. Warn when the fee is far above the suggestion; insufficiency is
// a hard error elsewhere, so never block here.
const TOKEN_FEE_WARN_FACTOR = 100n;

export const assessTokenFee = (feeSat: bigint, suggestedFeeSat: bigint): FeeAssessment => {
    if (feeSat <= 0n || suggestedFeeSat <= 0n) return { level: 'ok' };

    if (feeSat >= suggestedFeeSat * TOKEN_FEE_WARN_FACTOR) {
        return { level: 'warn', message: 'The fee looks unusually high — well above the suggested network fee.' };
    }

    return { level: 'ok' };
};
