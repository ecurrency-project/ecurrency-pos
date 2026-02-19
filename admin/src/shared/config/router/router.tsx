import { MainPage } from '@/pages/MainPage';
import { NotFoundPage } from '@/pages/NotFoundPage';
import type { RouteProps } from 'react-router-dom';
import { BlocksPage } from '@/pages/BlocksPage';
import { BlockDetailsPage } from '@/pages/BlockDetailsPage';
import { TransactionsPage } from '@/pages/TransactionsPage';
import { TxDetailsPage } from '@/pages/TxDetailsPage';
import { AddressPage } from '@/pages/AddressPage';
import { QrScannerPage } from '@/pages/QrScannerPage';
import { MyAddressesPage } from '@/pages/MyAddressesPage';


export const RoutersApp = {
    MAIN: 'main',
    BLOCKS: 'blocks',
    BLOCK_DETAIL: 'block_detail',
    TX: 'tx',
    TX_DETAIL: 'tx_detail',
    ADDRESS: 'address',
    QR_SCANNER: 'qr_scanner',
    MY_ADDRESSES: 'my_addresses',

    NOT_FOUND: 'not_found'
} as const

export type RoutersApp = typeof RoutersApp[keyof typeof RoutersApp]

export const RouterPath: Record<RoutersApp, string> = {
    [RoutersApp.MAIN]: '/',
    [RoutersApp.BLOCKS]: '/blocks',
    [RoutersApp.BLOCK_DETAIL]: '/blocks/:id',
    [RoutersApp.TX]: '/tx',
    [RoutersApp.TX_DETAIL]: '/tx/:id',
    [RoutersApp.ADDRESS]: '/address/:id',
    [RoutersApp.QR_SCANNER]: '/qr-scanner',
    [RoutersApp.MY_ADDRESSES]: '/my-addresses',

    [RoutersApp.NOT_FOUND]: '/*'
}

export const routerConfig: Record<RoutersApp, RouteProps> = {
    [RoutersApp.MAIN]: {
        path: RouterPath[RoutersApp.MAIN],
        element: <MainPage/>
    },
    [RoutersApp.BLOCKS]: {
        path: RouterPath[RoutersApp.BLOCKS],
        element: <BlocksPage/>
    },
    [RoutersApp.BLOCK_DETAIL]: {
        path: RouterPath[RoutersApp.BLOCK_DETAIL],
        element: <BlockDetailsPage/>
    },
    [RoutersApp.TX]: {
        path: RouterPath[RoutersApp.TX],
        element: <TransactionsPage/>
    },
    [RoutersApp.TX_DETAIL]: {
        path: RouterPath[RoutersApp.TX_DETAIL],
        element: <TxDetailsPage/>
    },
    [RoutersApp.ADDRESS]: {
        path: RouterPath[RoutersApp.ADDRESS],
        element: <AddressPage/>
    },

    [RoutersApp.QR_SCANNER]: {
        path: RouterPath[RoutersApp.QR_SCANNER],
        element: <QrScannerPage/>
    },
    [RoutersApp.MY_ADDRESSES]: {
        path: RouterPath[RoutersApp.MY_ADDRESSES],
        element: <MyAddressesPage/>
    },
    [RoutersApp.NOT_FOUND]: {
        path: RouterPath[RoutersApp.NOT_FOUND],
        element: <NotFoundPage/>
    }
}
