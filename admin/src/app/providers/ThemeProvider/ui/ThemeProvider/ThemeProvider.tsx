import { type FC, type ReactNode, useEffect, useMemo, useState } from 'react';
import { LOCAL_STORAGE_THEME_KEY, Theme, ThemeContext } from '../../lib/ThemeContext.ts';
import { ConfigProvider, theme as antTheme } from 'antd';
import { brand } from '@/brand';

const defaultTheme = localStorage.getItem(LOCAL_STORAGE_THEME_KEY) as Theme || Theme.LIGHT;

interface ThemeProviderProps {
    children: ReactNode;
}

// Mirrors the generated primary ramp into the CSS variables used outside antd.
const AccentVars = () => {
    const { token } = antTheme.useToken();

    useEffect(() => {
        if (!brand.accent) return;

        const { style } = document.body;
        style.setProperty('--dc-primary', token.colorPrimary);
        style.setProperty('--dc-primary-hover', token.colorPrimaryHover);
        style.setProperty('--dc-primary-bg', token.colorPrimaryBg);
        style.setProperty('--dc-primary-border', token.colorPrimaryBorder);
    }, [token]);

    return null;
};

export const ThemeProvider: FC<ThemeProviderProps> = ({ children }) => {
    const [theme, setTheme] = useState(defaultTheme);

    useEffect(() => {
        document.body.className = theme;
    }, [theme]);

    const defaultProps = useMemo(() => ({
        theme,
        setTheme,
    }), [theme]);

    const accent = brand.accent && (theme === Theme.DARK ? brand.accent.dark : brand.accent.light);

    return (
        <ThemeContext.Provider value={defaultProps}>
            <ConfigProvider theme={{
                algorithm: theme === Theme.DARK ? antTheme.darkAlgorithm : antTheme.defaultAlgorithm,
                token: {
                    "borderRadius": 4,
                    ...(accent ? { colorPrimary: accent } : {}),
                }
            }}>
                <AccentVars />
                {children}
            </ConfigProvider>
        </ThemeContext.Provider>
    );
}
