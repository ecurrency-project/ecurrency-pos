const isNumberChar = (char: string): boolean =>
    (char >= '0' && char <= '9') || char === '.' || char === 'e' || char === 'E'
    || char === '+' || char === '-';

const needsQuoting = (literal: string): boolean =>
    !/[.eE]/.test(literal) && !Number.isSafeInteger(Number(literal));

export const quoteBigIntegers = (text: string): string => {
    let out = '';
    let copied = 0;
    let i = 0;

    while (i < text.length) {
        const char = text[i];

        if (char === '"') {
            i += 1;
            while (i < text.length) {
                const inner = text[i];
                if (inner === '\\') {
                    i += 2;
                    continue;
                }
                i += 1;
                if (inner === '"') break;
            }
            continue;
        }

        if (char === '-' || (char >= '0' && char <= '9')) {
            const start = i;
            i += 1;
            while (i < text.length && isNumberChar(text[i])) i += 1;
            const literal = text.slice(start, i);
            if (needsQuoting(literal)) {
                out += text.slice(copied, start) + `"${literal}"`;
                copied = i;
            }
            continue;
        }

        i += 1;
    }

    return copied === 0 ? text : out + text.slice(copied);
};

export const parseJsonExact = (text: string): unknown => JSON.parse(quoteBigIntegers(text));

export const exactJsonResponseHandler = async (response: Response): Promise<unknown> => {
    const text = await response.text();

    return text.length ? parseJsonExact(text) : null;
};
