import { memo } from 'react';
import { Link } from 'react-router-dom';
import classNames from "classnames";

import { ThemeSwitcher } from '@/features/ThemeSwitcher';

import { HStack } from '@/shared/ui/Stack';
import { Logo } from '@/brand';

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
                <Logo height={50} width={127}/>
            </Link>
            <HStack>
                <ThemeSwitcher />
            </HStack>
        </HStack>
    )
});
