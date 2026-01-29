import { VStack } from '@/shared/ui/Stack';
import { Button } from '@/shared/ui/Button';

import cls from './ErrorPage.module.css';

export const ErrorPage = () => {
    const reloadPage = () => {
        window.location.reload();
    };

    return (
        <VStack gap="lg" align="center" justify='center' className={cls.wrapper}>
            <h1 className={cls.title}>Oops! Something went wrong</h1>
            <p className={cls.paragraph}>
                We apologize for the inconvenience. An unexpected error has occurred
            </p>
            <Button type="primary" onClick={reloadPage}>Reload Page</Button>
        </VStack>
    );
};
