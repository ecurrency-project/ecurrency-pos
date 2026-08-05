import {Link} from "react-router-dom";
import { formatNumber } from "@/shared/utils";
import { brand } from '@/brand';
import { TokenValue } from '@/entities/Token';
import type { Prevout, Vin, Vout } from '../model/types/ITransaction.ts';
import { satToNativeString } from '@/shared/lib/fmtbtc';
import { toBaseUnits } from '@/shared/lib/baseUnits';

export const NATIVE_PRECISION = 8;

const parentChainExplorerTxOut = '/tx/{txid}?output:{vout}';

export const linkToParentOut = (txid :string, vout: string, label=`${txid}:${vout}`) =>
    <Link to={parentChainExplorerTxOut.replace('{txid}', txid).replace('{vout}', vout)}>{label}</Link>

export const linkToAddr = (addr: string) =>
    <Link to={`/address/${addr}`}>{addr}</Link>


export const formatOutAmount = (vout: Prevout | Vout, assetLabel: string) => {
    if (vout.value == null) return `Confidential`;

    if (vout.token_amount != null && vout.token_id) {
        return <TokenValue
            tokenId={vout.token_id}
            amount={vout.token_amount}
            decimals={vout.token_decimals}
            link
        />
    }

    if (isNativeOut(vout)) {
        return <span>
      {formatNumber(satToNativeString(vout.value), NATIVE_PRECISION)}
            { ' ' }
            {!vout.asset ? assetLabel : <Link to={`/asset/${vout.asset}`}>{assetLabel}</Link>}
    </span>
    }
}

export const isRbf = (vins: Vin[]) => vins.some(vin => vin.sequence < 0xfffffffe);
export const isAllUnconfidential = (vouts: Vout[]) => vouts.every(vout => vout.value != null);

export const isNativeOut = (vout: Vout | Prevout) => (!vout.asset && !vout.assetcommitment) || vout.asset === brand.assetId
export const isAllNative = (vouts: Vout[]) => vouts.every(isNativeOut);
export const outTotal = (vouts: Vout[]): bigint =>
    vouts.reduce((total, vout) => total + (toBaseUnits(vout.value) ?? 0n), 0n);

