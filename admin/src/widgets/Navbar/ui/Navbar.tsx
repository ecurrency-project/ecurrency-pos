import { memo } from 'react';
import { Link } from 'react-router-dom';
import classNames from "classnames";

import { ThemeSwitcher } from '@/features/ThemeSwitcher';

import { HStack } from '@/shared/ui/Stack';

import LogoIcon from '@/shared/assets/icons/logo.svg?react';

import cls from "./Navbar.module.css";

interface NavbarProps {
    className?: string;
}

export const Navbar = memo(function Navbar(props: NavbarProps) {
    const { className } = props;

    return (
        <HStack
            justify="space-between"
            className={classNames(cls.Navbar, className, 'container')}
        >
            <Link className="navbar-brand" to="/">
                <LogoIcon height={50} width={127}/>
            </Link>
            <HStack>
                <ThemeSwitcher />
            </HStack>
        </HStack>
    )
});
