import {Link} from "react-router-dom";
import { formatNumber } from "@/shared/utils";
import { nativeAssetId, nativeAssetLabel } from '@/shared/const/const.ts';
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
            {!vout.asset ? nativeAssetLabel : <Link to={`/asset/${vout.asset}`}>{nativeAssetLabel}</Link>}
    </span>
    }


    //
    // const [ domain, ticker, name, _precision ] = vout.asset && assetMap && assetMap[vout.asset] || [];
    // const precision = _precision != null ? _precision : DEFAULT_ISSUED_PRECISION;
    // const short_id = vout.asset && vout.asset.substring(0, 10);
    // const asset_url = vout.asset && `asset/${vout.asset}`;
    //
    // const amount_el = formatAssetAmount(vout.value, precision, t);
    // const asset_link = vout.asset && <a href={asset_url}>{short_id}</a>
    //
    // return domain ? <span>{amount_el} {ticker && <span title={name}>{ticker}</span>} {shortDisplay||<br />} {domain}{shortDisplay || [<br/>,<em title={vout.asset}>{asset_link}</em>]}</span>
    //     : vout.asset ? <span>{amount_el} <em title={vout.asset}>{asset_link}</em></span>
    //         : <span>{amount_el} {t`Unknown`}</span> // should never happen
}

export const isRbf = (vins: Vin[]) => vins.some(vin => vin.sequence < 0xfffffffe);
export const isAllUnconfidential = (vouts: Vout[]) => vouts.every(vout => vout.value != null);

export const isNativeOut = (vout: Vout | Prevout) => (!vout.asset && !vout.assetcommitment) || vout.asset === nativeAssetId
export const isAllNative = (vouts: Vout[]) => vouts.every(isNativeOut);
export const outTotal = (vouts: Vout[]) => vouts.reduce((total, vout) => total + (+vout.value || 0), 0);

