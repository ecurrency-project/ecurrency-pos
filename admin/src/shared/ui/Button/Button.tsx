import type { ComponentProps, ReactNode } from 'react';
import { Button as AntButton } from 'antd';
import classNames from 'classnames';

import cls from './Button.module.css';

interface ButtonProps extends ComponentProps<typeof AntButton> {
    children?: ReactNode;
    className?: string;
    width?: string;
}

export const Button = ({ children, ...props } : ButtonProps) => {
    const { className, width, ...otherProps } = props;

    return (
        <AntButton
            {...otherProps}
            className={classNames(cls.Button, className)}
            style={{ width }}
        >
            {children}
        </AntButton>
    )
}

