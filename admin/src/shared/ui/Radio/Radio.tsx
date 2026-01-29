import { type InputHTMLAttributes, memo, type ChangeEvent, type ReactNode } from "react";
import classNames from "classnames";

import cls from './Radio.module.css';

type HTMLInputProps = Omit<InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange'>

interface RadioProps<T = string> extends HTMLInputProps {
    className?: string
    checked?: boolean
    onChange?: (value: T) => void
    name?: string
    label?: string | ReactNode;
    text?: string
    value?: T
    disabled?: boolean
}

function RadioComponent<T = string>(props: RadioProps<T>) {
    const {
        className,
        text,
        label,
        value,
        onChange,
        name,
        checked,
        disabled
    } = props;


    const onChangeHandler = (e: ChangeEvent<HTMLInputElement>) => {
        onChange?.(e.target.value as T);
    };

    return (
        <div className={classNames(cls.Radio, { [cls.disabled]: disabled }, [className])}>
            <label className={cls.label} htmlFor={`radio-${value}`}>
                <input
                    className={cls.inputHidden}
                    type="radio"
                    autoComplete="off"
                    name={name}
                    value={String(value)}
                    onChange={onChangeHandler}
                    checked={checked}
                    id={`radio-${value}`}
                    disabled={disabled}
                />
                <span className={cls.radio} />
                <span className={cls.title}>{label}</span>
            </label>
            {text && <span className={cls.subtitle}>{text}</span>}
        </div>
    )
}

export const Radio = memo(RadioComponent) as typeof RadioComponent;
