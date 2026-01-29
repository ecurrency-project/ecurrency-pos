import axios from 'axios';
import { isAddress, isHash256, isNumber } from '@/shared/utils';

const tryResource = async (path: string) => {
    const request = await axios.get(`/api/${path}`);
    return request.data;
}

export const searchRequest = async (query: string): Promise<string | null> => {
    query = query.trim();

    if (isNumber(query)) {
        try {
            const idBlock = await tryResource(`block-height/${query}`);
            return idBlock ? `/blocks/${idBlock}` : null;
        } catch {
            return null;
        }
    } else if (isHash256(query)) {
        try {
            const idTx = await tryResource(`tx/${query}`);
            return idTx ? `/tx/${query}` : null;
        } catch {
            try {
                const block = await tryResource(`block/${query}`);
                return block ? `/blocks/${query}` : null;
            } catch {
                return null;
            }
        }
    }
    else if (isAddress(query)) {
        try {
            await tryResource(`address/${query}`);
            return `/address/${query}`;
        } catch {
            return null;
        }
    }

    return null;
};
