import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'

import App from '@/app/App.tsx'

import './app/styles/index.css';

import { ErrorBoundaryProvider } from '@/app/providers/ErrorBoundary';
import { ThemeProvider } from '@/app/providers/ThemeProvider'

import { StoreProvider } from '@/app/providers/StoreProvider';

createRoot(document.getElementById('root')!).render(
    <BrowserRouter>
        <StoreProvider>
            <ErrorBoundaryProvider>
                <ThemeProvider>
                    <App/>
                </ThemeProvider>
            </ErrorBoundaryProvider>
        </StoreProvider>
    </BrowserRouter>
)
