import { Suspense } from 'react';
import { Route, Routes } from 'react-router-dom';

import { PageLoader } from '@/widgets/PageLoader';

import { routerConfig } from '@/shared/config/router/router';

function AppRouter() {

    return (
        <Routes>
            {Object.values(routerConfig).map((route) => (<Route
                key={route.path}
                path={route.path}
                element={<Suspense fallback={<PageLoader />}>
                    {route.element}
                </Suspense>}
            />))}
        </Routes>
    );
}

export default AppRouter;
