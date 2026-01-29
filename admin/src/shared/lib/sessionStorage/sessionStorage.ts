export const getSessionItem = (key: string) => {
    const value = sessionStorage.getItem(key);
    return value ? JSON.parse(value) : null;
}

export const removeSessionItem = (key: string) => {
    sessionStorage.removeItem(key);
}

export const setSessionItem = (key: string, value: unknown) => {
    sessionStorage.setItem(key, JSON.stringify(value))
}

export const clearSessionAll = () => {
    sessionStorage.clear();
}
