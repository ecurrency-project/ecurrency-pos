import { memo } from 'react';

import { useTheme, Theme } from '@/app/providers/ThemeProvider';

import { Button } from '@/shared/ui/Button';

import DarkModeIcon from '@/shared/assets/icons/dark_mode.svg?react';
import LightModeIcon from '@/shared/assets/icons/light_mode.svg?react';

interface ThemeSwitcherProps {
    className?: string;
}

export const ThemeSwitcher = memo(function ThemeSwitcher(props: ThemeSwitcherProps) {
    const { className } = props;
    const { theme, toggleTheme } = useTheme();

    return (
        <Button
            className={className}
            onClick={toggleTheme}
            icon={theme === Theme.DARK ? <LightModeIcon width={24} height={24} /> : <DarkModeIcon width={24} height={24} />}
            shape='circle'
            type='text'
        />
    );
});
