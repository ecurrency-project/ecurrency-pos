import {memo} from "react";
import {Link} from "react-router-dom";
import classNames from "classnames";

import { SearchBar } from "@/features/Search";

import { RouterPath } from '@/shared/config/router/router.tsx';

import cls from "./SubNavbar.module.css";

interface SubNavbarProps {
    className?: string;
}

export const SubNavbar = memo(function SubNavbar(props: SubNavbarProps) {
    const { className } = props;
    return (
        <div className={classNames(cls.SubNavbar, className)}>
            <div className={classNames(cls.SubNavbarContainer, 'container')}>
                <div className={cls.SubNav}>
                    <Link to={RouterPath.main}>Dashboard</Link>
                    <Link to={RouterPath.blocks}>Blocks</Link>
                    <Link to={RouterPath.tx}>Transactions</Link>
                </div>
                <SearchBar />
            </div>
        </div>
    )
});
