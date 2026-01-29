import { type ChangeEvent, type ComponentProps, memo } from 'react';
import { Input as AntInput } from 'antd';

import { VStack } from '../Stack';

import cls from './Input.module.css';

interface InputPasswordProps extends Omit<ComponentProps<typeof AntInput.Password>, 'onChange'> {
    value?: string;
    onChange: (value: string) => void;
    className?: string;
    label?: string;
    placeholder?: string;
    disabled?: boolean;
    id?: string;
    status?: 'error' | 'warning';
}

export const InputPassword = memo(function InputPassword(props: InputPasswordProps) {
    const {
        className,
        onChange,
        label,
        ...restProps
    } = props;

    const onChangeHandler = (e: ChangeEvent<HTMLInputElement>) => {
        onChange(e.target.value);
    }

    return (
        <VStack gap='xs' maxWidth className={className}>
            {label && <label className={cls.label}>{label}</label>}
            <AntInput.Password
                onChange={onChangeHandler}
                {...restProps}
            />
        </VStack>
    )
});
