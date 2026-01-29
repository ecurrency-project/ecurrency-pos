import { useContext } from 'react';

import { LOCAL_STORAGE_THEME_KEY, Theme, ThemeContext } from './ThemeContext.ts';

interface UseThemeResult {
    toggleTheme: () => void;
    theme: Theme;
}

export const useTheme = (): UseThemeResult => {
    const { theme, setTheme } = useContext(ThemeContext);

    const toggleTheme = () => {
        const newTheme = theme === Theme.LIGHT ? Theme.DARK : Theme.LIGHT;
        localStorage.setItem(LOCAL_STORAGE_THEME_KEY, newTheme);
        if (setTheme) {
            setTheme(newTheme);
        }
    };

    return {
        theme: theme || Theme.LIGHT,
        toggleTheme,
    };
}
