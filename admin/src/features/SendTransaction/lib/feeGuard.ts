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
