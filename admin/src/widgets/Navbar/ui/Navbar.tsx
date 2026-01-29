import { memo } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import classNames from "classnames";

import { ThemeSwitcher } from '@/features/ThemeSwitcher';

import { HStack } from '@/shared/ui/Stack';
import { Button } from '@/shared/ui/Button';

import LogoIcon from '@/shared/assets/icons/logo.svg?react';

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
                <LogoIcon height={50} width={127}/>
            </Link>
            <HStack>
                <Button type='dashed' onClick={() => navigate('/whitepaper')}>Docs</Button>
                <ThemeSwitcher />
            </HStack>
        </HStack>
    )
});
