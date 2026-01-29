import { Input as AntInput } from "antd";
import { type ComponentProps, memo } from "react";

import { VStack } from "../Stack";

import cls from './Input.module.css';

interface InputOTPProps extends Omit<ComponentProps<typeof AntInput.OTP>, 'onChange'> {
    value?: string;
    onChange: (value: string) => void;
    className?: string;
    label?: string;
}

export const InputOTP = memo(function InputOTP(props: InputOTPProps) {
    const {
        value,
        onChange,
        className,
        label,
        ...restProps
    } = props;

    return (
        <VStack gap='xs' maxWidth className={className}>
            {label && <label className={cls.label}>{label}</label>}
            <div className={cls.inputOTP}>
                <AntInput.OTP
                    value={value}
                    onChange={onChange}
                    autoFocus
                    inputMode='numeric'
                    style={{ width: '100%' }}
                    {...restProps}
                />
            </div>
        </VStack>
    )
});
