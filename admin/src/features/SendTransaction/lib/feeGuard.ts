export type FeeRisk = 'ok' | 'warn' | 'block';

export interface FeeAssessment {
    level: FeeRisk;
    message?: string;
    percent?: number;
}

const WARN_PERCENT = 10;

export const assessFee = (amountSat: number, feeSat: number): FeeAssessment => {
    if (amountSat <= 0 || feeSat <= 0) return { level: 'ok' };

    if (feeSat >= amountSat) {
        return {
            level: 'block',
            message: "The fee is higher than the amount you're sending. Lower the fee or raise the amount.",
        };
    }

    if (feeSat * 100 >= amountSat * WARN_PERCENT) {
        const percent = Math.floor((feeSat * 100) / amountSat);
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
const TOKEN_FEE_WARN_FACTOR = 100;

export const assessTokenFee = (feeSat: number, suggestedFeeSat: number): FeeAssessment => {
    if (feeSat <= 0 || suggestedFeeSat <= 0) return { level: 'ok' };

    if (feeSat >= suggestedFeeSat * TOKEN_FEE_WARN_FACTOR) {
        return { level: 'warn', message: 'The fee looks unusually high — well above the suggested network fee.' };
    }

    return { level: 'ok' };
};
