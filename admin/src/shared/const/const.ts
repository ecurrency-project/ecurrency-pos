// Pagination
export const blockTxsPerPage = 25;
export const addrTxsPerPage = 25;
export const blocksPerPage = 10;
export const maxMempoolTxs = 50;
export const assetTxsPerPage = 25; // Elements only
export const pegTxsPerPage = 25;   // Elements only
export const LATEST_BLOCKS_DISPLAY_COUNT = 5;

// Coin units (8 decimals as in Bitcoin)
export const COIN_DECIMALS = 8;
export const SAT_PER_COIN = 10 ** COIN_DECIMALS;

// Polling intervals (ms)
export const MEMPOOL_RECENT_PULL_INTERVAL = 5000;
export const TIP_HEIGHT_POLL_INTERVAL = 5000;
export const CHAIN_STATUS_POLL_INTERVAL = 10000;
export const TX_POLL_INTERVAL = 15000;
export const BALANCE_POLL_INTERVAL = 10000;

// Confirmations
export const TX_MIN_CONFIRMATIONS = 20;

// Timeouts (ms)
export const CLIPBOARD_TOOLTIP_TIMEOUT = 2000;

// UI
export const MOBILE_BREAKPOINT = 768;
export const FORM_MAX_WIDTH = 600;

// Unit conversion
export const BYTES_PER_KB = 1000;
export const UNITS_PER_GW = 1000000000;
