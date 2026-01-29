import type { ElementType, HTMLAttributes, JSX, ReactNode } from 'react';
import classNames from 'classnames';

import cls from './Flex.module.css';

export type FlexJustify = 'start' | 'end' | 'center' | 'space-between' | 'space-around';
export type FlexAlign = 'start' | 'end' | 'center' | 'stretch';
export type FlexDirection = 'row' | 'column';
export type FlexGap = 'none' | 'xs' | 'sm' | 'md' | 'lg' | 'xl' | 'xxl';

const justifyMap: Record<FlexJustify, string> = {
    start: cls.justifyStart,
    end: cls.justifyEnd,
    center: cls.justifyCenter,
    'space-between': cls.justifyBetween,
    'space-around': cls.justifyAround,
};

const alignMap: Record<FlexAlign, string> = {
    start: cls.alignStart,
    end: cls.alignEnd,
    center: cls.alignCenter,
    stretch: cls.alignStretch,
};

const directionMap: Record<FlexDirection, string> = {
    row: cls.directionRow,
    column: cls.directionColumn,
};

const gapMap: Record<FlexGap, string> = {
    none: cls.gapNone,
    xs: cls.gapXs,
    sm: cls.gapSm,
    md: cls.gapMd,
    lg: cls.gapLg,
    xl: cls.gapXl,
    xxl: cls.gapXxl,
};

export interface FlexProps<T extends keyof JSX.IntrinsicElements = 'div'> extends Omit<HTMLAttributes<HTMLElement>, 'className'> {
    children: ReactNode;
    className?: string;
    justify?: FlexJustify;
    align?: FlexAlign;
    direction?: FlexDirection;
    gap?: FlexGap;
    maxWidth?: boolean;
    as?: T;
}

export const Flex = <T extends keyof JSX.IntrinsicElements = 'div'>(props: FlexProps<T>) => {
    const {
        children,
        className,
        justify = 'start',
        align = 'center',
        direction = 'row',
        gap = 'xs',
        maxWidth = false,
        as = 'div' as T,
        ...otherProps
    } = props;

    const Component = as as ElementType;

    const mods = {
        [cls.maxWidth]: maxWidth,
    };

    const classes = [
        className,
        justifyMap[justify],
        alignMap[align],
        directionMap[direction],
        gapMap[gap],
    ];

    return (
        <Component className={classNames(cls.Flex, mods, classes)} {...otherProps}>
            {children}
        </Component>
    );
};
