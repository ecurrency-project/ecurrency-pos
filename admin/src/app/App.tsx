import { AppRouter } from '@/app/providers/RouterProvider';

import { Navbar } from '@/widgets/Navbar';
import { SubNavbar } from '@/widgets/SubNavbar';
import { Footer } from '@/widgets/Footer';

import { useGetTipHeightQuery } from '@/entities/TipHeight';

import { TIP_HEIGHT_POLL_INTERVAL } from '@/shared/const/const.ts';

function App() {
    useGetTipHeightQuery(undefined, {
        pollingInterval: TIP_HEIGHT_POLL_INTERVAL,
    });

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
