import { useSyncExternalStore } from 'react';

import type { ChainStatus } from '../model/types/chainStatus';


function getNowSec(): number {
    return Math.floor(Date.now() / 1000);
}

function subscribe(callback: () => void): () => void {
    const id = setInterval(callback, 1000);
    return () => clearInterval(id);
}

export function useSyncProgress(status: ChainStatus | undefined): number | null {
    const nowSec = useSyncExternalStore(subscribe, getNowSec, getNowSec);

    if (!status?.initialblockdownload) return null;

    const total = nowSec - status.genesistime;
    const synced = status.bestblocktime - status.genesistime;
    if (total <= 0) return 0;
    return Math.min(100, Math.max(0, (synced / total) * 100));
}
