import { useEffect } from 'react';

import { AppRouter } from '@/app/providers/RouterProvider';

import { Navbar } from '@/widgets/Navbar';
import { SubNavbar } from '@/widgets/SubNavbar';
import { Footer } from '@/widgets/Footer';

import { tipHeightFetch } from '@/entities/TipHeight';

import { useRecurringTimeout, useAppDispatch } from '@/shared/lib/hooks';

function App() {
    const dispatch = useAppDispatch();

    useEffect(() => {
        dispatch(tipHeightFetch());
    }, [dispatch]);

    useRecurringTimeout(() => {
        dispatch(tipHeightFetch());
    }, 60000);

    return (
        <div className="app">
            <div className='content-wrap'>
                <Navbar/>
                <SubNavbar/>
                <AppRouter/>
            </div>
            <Footer/>
        </div>
    )
}

export default App
