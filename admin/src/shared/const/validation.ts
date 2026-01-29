const PHONE_RE = /^\+(?=(?:[0-9][^0-9]*){8,16}$)[1-9](?: *-? *(?:[0-9]|\([0-9]+\)))+[0-9]$/;
const TELEGRAM_RE = /^@[a-zA-Z][a-zA-Z0-9_\-,.:]{3,63}$|^\+(?=(?:[0-9][^0-9]*){8,16})[1-9](?: *-? *(?:[0-9]|\([0-9]+\)))+[0-9]$/;
const BIRTHDAY_RE = /^(?:(?:19[1-9][0-9]|20[01][0-9])-(?:0[1-9]|1[0-2])-(?:[0-2][0-9]|3[01]))?$/;
const PASSPORT_RE = /^.{4,64}$/;

export const emailValidator = (value: string) => {
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
};

export const passwordValidator = (value: string) => {
    return /(?=^.{6,128}$)(?=.*[0-9])(?=.*[a-zA-Z]).*$/.test(value);
};

export const codeValidator = (value: string) => {
    return /^\d{6}$/.test(value);
};

export const phoneValidator = (value: string) => {
    if (!value) {
        return true;
    }
    return PHONE_RE.test(value);
};

export const nameValidator = (value: string) => {
    return value.trim().length > 1 && value.trim().length < 64 && /^[\p{L}\p{N}]+$/u.test(value);
};

export const telegramValidator = (value: string) => {
    return TELEGRAM_RE.test(value);
};

export const birthdayValidator = (value: string) => {
    return BIRTHDAY_RE.test(value);
};

export const passportValidator = (value: string) => {
    return PASSPORT_RE.test(value);
}
