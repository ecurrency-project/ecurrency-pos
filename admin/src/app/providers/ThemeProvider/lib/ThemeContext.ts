import { createContext } from 'react';

export const Theme = {
    LIGHT: 'app_light_theme',
    DARK: 'app_dark_theme',
} as const;

export type Theme = typeof Theme[keyof typeof Theme];

export interface ThemeContentProps {
    theme?: Theme
    setTheme?: (theme: Theme) => void
}

export const LOCAL_STORAGE_THEME_KEY = 'theme';

export const ThemeContext = createContext<ThemeContentProps>({});
