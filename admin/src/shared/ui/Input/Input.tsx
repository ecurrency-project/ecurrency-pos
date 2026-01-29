import type { ChangeEvent, ComponentProps } from 'react';
import { Input as AntInput } from "antd";

import { VStack } from "../Stack";

import cls from './Input.module.css';

interface InputProps extends Omit<ComponentProps<typeof AntInput>, 'onChange'>{
    onChange?: (value: string) => void;
    value?: string;
    label?: string;
    placeholder?: string;
    disabled?: boolean;
    id?: string;
    status?: 'error' | 'warning';
    type?: 'text' | 'password' | 'email' | 'tel';
    className?: string;
    extend?: string;
}

export const Input = (props: InputProps) => {
    const {
        onChange,
        value,
        label,
        placeholder,
        disabled,
        id,
        className,
        ...restProps
    } = props;

    const onChangeHandler = (e: ChangeEvent<HTMLInputElement>) => {
        onChange?.(e.target.value);
    }

    return (
        <VStack gap='xs' maxWidth className={className}>
            {label && <label className={cls.label}>{label}</label>}
            <AntInput
                onChange={onChangeHandler}
                value={value}
                placeholder={placeholder}
                disabled={disabled}
                id={id}
                {...restProps}
            />
        </VStack>
    )
}
