import { memo, useState } from 'react';
import { Tooltip } from 'antd';
import classNames from 'classnames';

import { Button } from '@/shared/ui/Button';

import { CLIPBOARD_TOOLTIP_TIMEOUT } from '@/shared/const/const.ts';
import CopySvg from '@/shared/assets/icons/copy.svg?react';

import cls from './Clipboard.module.css';

interface ClipboardProps {
    className?: string
    text: string
}

export const Clipboard = memo(function Clipboard(props: ClipboardProps) {
    const {
        className,
        text,
    } = props;

    const [showTooltip, setShowTooltip] = useState(false);

    const handleCopy = () => {
        if (navigator.clipboard) {
            navigator.clipboard.writeText(text)
                .then(() => {
                    setShowTooltip(true);
                    setTimeout(() => setShowTooltip(false), CLIPBOARD_TOOLTIP_TIMEOUT);
                })
                .catch((error) => {
                    console.error('Failed to copy text:', error);
                });
        } else if (document.queryCommandSupported('copy')) {
            const textarea = document.createElement('textarea');
            textarea.value = text;
            textarea.style.position = 'fixed';
            document.body.appendChild(textarea);
            textarea.select();
            try {
                document.execCommand('copy');
                setShowTooltip(true);
                setTimeout(() => setShowTooltip(false), CLIPBOARD_TOOLTIP_TIMEOUT);
            } catch (error) {
                console.error('Failed to copy text:', error);
            } finally {
                document.body.removeChild(textarea);
            }
        } else {
            console.error('Copy to clipboard is not supported in this browser.');
        }
    };

    return (
        <div className={classNames(cls.Clipboard, className)} onClick={handleCopy}>
            <div className={cls.text}>
                {text}
            </div>
            <Tooltip title='Copied!' placement="bottom" open={showTooltip}>
                <Button icon={<CopySvg width={20} height={20} />} type='text' shape='circle'/>
            </Tooltip>
        </div>
    );
});
