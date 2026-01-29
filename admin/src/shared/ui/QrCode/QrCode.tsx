import { memo } from 'react';
import { Space as AntSpace, QRCode as AntQRCode } from 'antd';

interface QrCodeProps {
    value?: string;
    className?: string;
}

export const QrCode = memo(function QrCode(props: QrCodeProps) {
    const {
        value,
        className,
    } = props;

    if (!value) {
        return null;
    }

    return (
        <AntSpace className={className}>
            <AntQRCode value={value} />
        </AntSpace>
    );
});
