import {memo, type ReactNode} from "react";
import { useTranslation } from 'react-i18next';
import { Link } from "react-router-dom";
import classNames from "classnames";

import { HStack, VStack } from '@/shared/ui/Stack';
import { formatNumber } from '@/shared/utils';
import { moveDecimalPoint } from '@/shared/lib/moveDecimalPoint';

import type { Vin } from '../../model/types/ITransaction.ts';

import { formatOutAmount, linkToAddr, linkToParentOut } from '../utils.tsx';

import cls from './TxVin.module.css';

interface TransactionVinProps {
    className?: string
    vin: Vin;
    index?: number;
    expanded?: boolean;
}

export const TxVin = memo(function TxVin(props: TransactionVinProps) {
    const {
        className,
        vin,
        index,
        expanded,
    } = props;

    const { t } = useTranslation();

    const wrapper = (children: ReactNode, description: ReactNode) => (
        <div className={classNames(cls.TransactionVin, className)}>
            <div className={cls.header}>
                <HStack align="start">
                    <span className={cls.index}>{`#${index}`}</span>
                    <div className={cls.wrapper}>
                        {description}
                        <span className={cls.amount}>{vin.prevout && formatOutAmount(vin.prevout)}</span>
                    </div>
                </HStack>
            </div>
            {children}
        </div>
    )

    if (vin.is_pegin) {
        const description = linkToParentOut(vin.txid, vin.vout.toString(), t('_output_in_parent_chain'));
        const body = (
            <div className="vin-body">
                <div>
                    <div>{t('txid:vout')}</div>
                    <div className="mono">{linkToParentOut(vin.txid, vin.vout.toString())}</div>
                </div>
            </div>
        );

        return wrapper(body, description);
    }

    const description = vin.is_coinbase
        ? t('_coinbase')
        : <Link to={`/tx/${vin.txid}?output:${vin.vout}`}>{`${vin.txid}:${vin.vout}`}</Link>;

    const body = (
        expanded ? <VStack gap="sm" className={classNames(cls.vinBody)}>
            {vin.issuance && <>
                <div className={cls.vinBodyRow}>
                    <div>{t('_issuance')}</div>
                    <div>{t(vin.issuance.is_reissuance ? '_reissuance' : '_new_asset')}</div>
                </div>
                <div className={cls.vinBodyRow}>
                    <div>{t('_issued_asset_id')}</div>
                    <div className="mono"><Link to={`/asset/${vin.issuance.asset_id}`}>{vin.issuance.asset_id}</Link></div>
                </div>
                {vin.issuance.contract_hash &&
                    <div className={cls.vinBodyRow}>
                        <div>{t('_contract_hash')}</div>
                        <div className="mono">{vin.issuance.contract_hash}</div>
                    </div>
                }

                <div className={cls.vinBodyRow}>
                    <div>{t('_asset_entropy')}</div>
                    <div className="mono">{vin.issuance.asset_entropy}</div>
                </div>

                {/*<div className={cls.vinBodyRow}>*/}
                {/*    <div>{!vin.issuance.assetamountcommitment ? t`Issued amount` : t`Amount commitment`}</div>*/}
                {/*    <div>{!vin.issuance.assetamountcommitment ? formatAssetAmount(vin.issuance.assetamount, assetMeta ? assetMeta[3] : 0, t)*/}
                {/*        : <span className="mono">{vin.issuance.assetamountcommitment}</span>}</div>*/}
                {/*</div>*/}

                {!vin.issuance.is_reissuance &&
                    <div className={cls.vinBodyRow}>
                        <div>{t(!vin.issuance.tokenamountcommitment ? '_reissuance_tokens' : '_reissuance_tokens_commitment')}</div>
                        <div>{!vin.issuance.tokenamountcommitment ? (!vin.issuance.tokenamount ? t('_no_reissuance') : formatNumber(vin.issuance.tokenamount))
                            : <span className="mono">{vin.issuance.tokenamountcommitment}</span>}</div>
                    </div>
                }

                {vin.issuance.asset_blinding_nonce &&
                    <div className={cls.vinBodyRow}>
                        <div>{t('_issuance_blinding_nonce')}</div>
                        <div className="mono">{vin.issuance.asset_blinding_nonce}</div>
                    </div>
                }
            </>}

            {vin.scriptsig && <>
                <div className={cls.vinBodyRow}>
                    <div>{t('_scriptsig_asm')}</div>
                    <div className="mono">{vin.scriptsig_asm}</div>
                </div>
                <div className={cls.vinBodyRow}>
                    <div>{t('_scriptsig_hex')}</div>
                    <div className="mono">{vin.scriptsig}</div>
                </div>
            </>}

            {vin.inner_redeemscript_asm && <div className={cls.vinBodyRow}>
                <div>{t('_p2sh_redeem_script')}</div>
                <div className="mono">{vin.inner_redeemscript_asm}</div>
            </div>}

            {vin.redeem_script && <div className={cls.vinBodyRow}>
                <div>{t('_redeem_script')}</div>
                <div>{vin.redeem_script}</div>
            </div>}

            {vin.siglist && <div className={cls.vinBodyRow}>
                <div>{t('_signatures')}</div>
                {vin.siglist.map((signature, index) => <div key={`${signature}_${index}`} className="mono">{signature}</div>)}
            </div>}

            {vin.prevout && <>
                <div className={cls.vinBodyRow}>
                    <div>{t('_previous_output_scripthash')}</div>
                    <div>
                        {vin.prevout.scripthash}
                        {vin.prevout.scriptpubkey_type && <em> ({vin.prevout.scriptpubkey_type})</em>}
                    </div>
                </div>

                {vin.prevout.scripthash_address && <div className={cls.vinBodyRow}>
                    <div>{t('_previous_output_address')}</div>
                    <div>{linkToAddr(vin.prevout.scripthash_address)}</div>
                </div>}

                { vin.prevout.token_id &&
                    <div className={cls.vinBodyRow}>
                        <div>{t('token id')}</div>
                        <div className="mono">{vin.prevout.token_id}</div>
                    </div>
                }

                { vin.prevout.token_amount !== undefined && vin.prevout.token_amount !== 0 &&
                    <div className={cls.vinBodyRow}>
                        <div>{t('token amount')}</div>
                        <div className="mono">{moveDecimalPoint(vin.prevout.token_amount, -(vin.prevout.token_decimals ?? 0))}</div>
                    </div>
                }

                { vin.prevout.token_permissions !== undefined &&
                    <div className={cls.vinBodyRow}>
                        <div>{t('token permissions')}</div>
                        <div className="mono">{vin.prevout.token_permissions}</div>
                    </div>
                }
            </>}
        </VStack> : null
    )

    return wrapper(
        body,
        description,
    )
})
