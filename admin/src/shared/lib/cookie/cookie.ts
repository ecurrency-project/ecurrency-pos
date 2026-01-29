export const getCookie = (name: string) => {
    const ARRCookies = document.cookie.split(";");
    const cookie = ARRCookies.find((cookie) => cookie.substring(0, cookie.indexOf("=")).trim() === name);

    if (cookie) {
        return decodeURIComponent(cookie.substring(cookie.indexOf("=") + 1, cookie.length));
    }

    return '';
}

export const setCookie = (name: string, value: string, days: number, forceDomain: boolean) => {
    let expires = '';
    if (days) {
        const date = new Date();
        date.setTime(date.getTime() + (days * 24 * 60 * 60 * 1000));
        expires = `; expires=${date.toUTCString()}`;
    }
    const domain = window.location.hostname;
    document.cookie = `${name}=${value || ''}${expires}; path=/${forceDomain ? `; domain=${domain}` : ''}`;
}

export const deleteCookie = (name: string) => {
    document.cookie = `${name}=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/;`;
}

export const clearAllCookies = () => {
    document.cookie.split(";").forEach((cookie) => {
        document.cookie = cookie.replace(/^ +/, "").replace(/=.*/, `=;expires=Thu, 01 Jan 1970 00:00:00 UTC;path=/`);
    });
}
