import classNames from 'classnames';

import { brand } from '@/brand';

import cls from './NativeCoinIcon.module.css';

interface NativeCoinIconProps {
    className?: string;
}

export const NativeCoinIcon = ({ className }: NativeCoinIconProps) => {
    const BrandCoinIcon = brand.CoinIcon;

    if (BrandCoinIcon) {
        return <BrandCoinIcon className={classNames(cls.svg, className)} aria-hidden="true" />;
    }

    return (
        <span className={classNames(cls.monogram, className)} aria-hidden="true">
            {(brand.assetLabel[0] || '?').toUpperCase()}
        </span>
    );
};
