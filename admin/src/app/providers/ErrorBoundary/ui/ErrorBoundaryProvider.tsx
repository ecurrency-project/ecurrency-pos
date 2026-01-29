import { Component, type ErrorInfo, type ReactNode, Suspense } from 'react';
import { ErrorPage } from '@/app/providers/ErrorBoundary/ui/ErrorPage.tsx';

interface ErrorBoundaryProps {
    children: ReactNode;
}

interface ErrorBoundaryState {
    hasError: boolean;
}

class ErrorBoundaryProvider extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
    constructor(props: ErrorBoundaryProps) {
        super(props);
        this.state = { hasError: false };
    }

    static getDerivedStateFromError() {
        return { hasError: true };
    }

    componentDidCatch(error: Error, errorInfo: ErrorInfo) {
        console.error('Uncaught error:', error, errorInfo);
    }

    render() {
        const { hasError } = this.state;
        const { children } = this.props;

        if (hasError) {
            return (
                <Suspense fallback="">
                    <ErrorPage />
                </Suspense>
            );
        }

        return children;
    }
}

export default ErrorBoundaryProvider;
