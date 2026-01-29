import { memo, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import QrScanner from "qr-scanner";

import { searchRequest } from '@/features/Search';

import { Button } from '@/shared/ui/Button';
import { RouterPath } from '@/shared/config/router/router.tsx';

import cls from './QrScannerPage.module.css';

const QrScannerPage = memo(function QrScannerPage() {
    const scanner = useRef<QrScanner>(null);
    const videoRef = useRef<HTMLVideoElement>(null);
    const [qrOn, setQrOn] = useState<boolean>(true);

    const navigate = useNavigate();

    const onScanSuccess = (scanResult: QrScanner.ScanResult) => {
        // 🖨 Print the "result" to the browser console.
        if (scanResult?.data) {
            console.log(scanResult.data);
            scanner?.current?.stop();
            searchRequest(scanResult.data).then((res) => {
                console.log('searchRequest', res)
                navigate(res ? res : '/not-found', { state: { query: 'No results found' } });
            });
        }
    };

    // Fail
    const onScanFail = (err: string | Error) => {
        console.log(err);
    };

    useEffect(() => {
        if (videoRef?.current && !scanner.current) {
            // 👉 Instantiate the QR Scanner
            scanner.current = new QrScanner(videoRef?.current, onScanSuccess, {
                onDecodeError: onScanFail,
                preferredCamera: "environment",
                highlightScanRegion: true,
                highlightCodeOutline: true,
                maxScansPerSecond: 2,
            });

            scanner?.current
                ?.start()
                .then(() => {
                    setQrOn(true)
                    console.log("QR Scanner started")
                })
                .catch((err) => {
                    if (err) setQrOn(false);
                });
        }

        return () => {
            if (!videoRef?.current) {
                scanner?.current?.stop();
            }
        };
    }, []);

    useEffect(() => {
        if (!qrOn)
            alert(
                "Camera is blocked or not accessible. Please allow camera in your browser permissions and Reload."
            );
    }, [qrOn]);

    return (
        <div className={cls.QrScannerPage}>
            {/* QR */}
            <video className={cls.video} ref={videoRef}></video>

            <Button
                className={cls.cancel}
                onClick={() => {
                    navigate(RouterPath.main);
                }}
            >
                Cancel
            </Button>
        </div>
    );
});

export default QrScannerPage;
