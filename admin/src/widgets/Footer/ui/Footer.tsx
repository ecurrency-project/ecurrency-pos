import { memo } from "react";
import classNames from "classnames";

import { HStack } from "@/shared/ui/Stack";
import { brand } from "@/brand";

import cls from "./Footer.module.css";

export const Footer = memo(function Footer() {
    const currentYear = new Date().getFullYear();

    return (
        <footer className={classNames(cls.Footer, 'container')}>
            <HStack>
                <span>{currentYear} ©</span>
                <span>{brand.assetName} Explorer</span>
            </HStack>
        </footer>
    );
});
