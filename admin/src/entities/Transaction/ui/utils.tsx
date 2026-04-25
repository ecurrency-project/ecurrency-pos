import {Link} from "react-router-dom";
import { formatNumber } from "@/shared/utils";
import { brand } from '@/brand';
import type { Prevout, Vin, Vout } from '../model/types/ITransaction.ts';
import { sat2btc } from '@/shared/lib/fmtbtc';

export const NATIVE_PRECISION = 8;

const parentChainExplorerTxOut = '/tx/{txid}?output:{vout}';

export const linkToParentOut = (txid :string, vout: string, label=`${txid}:${vout}`) =>
    <Link to={parentChainExplorerTxOut.replace('{txid}', txid).replace('{vout}', vout)}>{label}</Link>

export const linkToAddr = (addr: string) =>
    <Link to={`/address/${addr}`}>{addr}</Link>


export const formatOutAmount = (vout: Prevout | Vout) => {
    if (vout.value == null) return `Confidential`;

    if (isNativeOut(vout)) {
        return <span>
      {formatNumber(sat2btc(vout.value), NATIVE_PRECISION)}
            { ' ' }
            {!vout.asset ? brand.assetLabel : <Link to={`/asset/${vout.asset}`}>{brand.assetLabel}</Link>}
    </span>
    }
}

export const isRbf = (vins: Vin[]) => vins.some(vin => vin.sequence < 0xfffffffe);
export const isAllUnconfidential = (vouts: Vout[]) => vouts.every(vout => vout.value != null);

export const isNativeOut = (vout: Vout | Prevout) => (!vout.asset && !vout.assetcommitment) || vout.asset === brand.assetId
export const isAllNative = (vouts: Vout[]) => vouts.every(isNativeOut);
export const outTotal = (vouts: Vout[]) => vouts.reduce((total, vout) => total + (+vout.value || 0), 0);

