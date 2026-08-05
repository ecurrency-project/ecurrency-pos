import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'

import App from '@/app/App.tsx'

import './app/styles/index.css';

import { ErrorBoundaryProvider } from '@/app/providers/ErrorBoundary';
import { ThemeProvider } from '@/app/providers/ThemeProvider'

import { StoreProvider } from '@/app/providers/StoreProvider';
import { NetworkProvider } from '@/app/providers/NetworkProvider';

createRoot(document.getElementById('root')!).render(
    <BrowserRouter>
        <StoreProvider>
            <ErrorBoundaryProvider>
                <NetworkProvider>
                    <ThemeProvider>
                        <App/>
                    </ThemeProvider>
                </NetworkProvider>
            </ErrorBoundaryProvider>
        </StoreProvider>
    </BrowserRouter>
)
