import { memo } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { SettingOutlined } from '@ant-design/icons';
import classNames from "classnames";

import { ThemeSwitcher } from '@/features/ThemeSwitcher';

import { HStack } from '@/shared/ui/Stack';
import { Button } from '@/shared/ui/Button';
import { RouterPath } from '@/shared/config/router/router.tsx';
import { Logo } from '@/brand';

import cls from "./Navbar.module.css";

interface NavbarProps {
    className?: string;
}

export const Navbar = memo(function Navbar(props: NavbarProps) {
    const { className } = props;
    const navigate = useNavigate();

    return (
        <HStack
            justify="space-between"
            className={classNames(cls.Navbar, className, 'container')}
        >
            <Link className="navbar-brand" to="/">
                <Logo height={50} width={127}/>
            </Link>
            <HStack>
                <Button
                    onClick={() => navigate(RouterPath.settings)}
                    icon={<SettingOutlined style={{ fontSize: 20 }} />}
                    shape='circle'
                    type='text'
                    aria-label="Settings"
                />
                <ThemeSwitcher />
            </HStack>
        </HStack>
    )
});
