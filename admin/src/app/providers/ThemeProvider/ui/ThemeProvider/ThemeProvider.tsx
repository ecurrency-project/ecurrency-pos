import { type FC, type ReactNode, useEffect, useMemo, useState } from 'react';
import { LOCAL_STORAGE_THEME_KEY, Theme, ThemeContext } from '../../lib/ThemeContext.ts';
import { ConfigProvider, theme as antTheme } from 'antd';

const defaultTheme = localStorage.getItem(LOCAL_STORAGE_THEME_KEY) as Theme || Theme.LIGHT;

interface ThemeProviderProps {
    children: ReactNode;
}

export const ThemeProvider: FC<ThemeProviderProps> = ({ children }) => {
    const [theme, setTheme] = useState(defaultTheme);

    useEffect(() => {
        document.body.className = theme;
    }, [theme]);

    const defaultProps = useMemo(() => ({
        theme,
        setTheme,
    }), [theme]);

    return (
        <ThemeContext.Provider value={defaultProps}>
            <ConfigProvider theme={{
                algorithm: theme === Theme.DARK ? antTheme.darkAlgorithm : antTheme.defaultAlgorithm,
                token: {
                    "borderRadius": 4
                }
            }}>
                {children}
            </ConfigProvider>
        </ThemeContext.Provider>
    );
}
