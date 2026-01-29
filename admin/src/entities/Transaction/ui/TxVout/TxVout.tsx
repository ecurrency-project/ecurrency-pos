import { memo, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import classNames from "classnames";

import { HStack, VStack } from '@/shared/ui/Stack';

import type { ISpend, Vout } from '../../model/types/ITransaction.ts';

import { formatOutAmount, linkToAddr } from '../utils.tsx';

import cls from './TxVout.module.css';

interface TransactionVoutProps {
    className?: string
    vout: Vout;
    index?: number
    expanded?: boolean;
    spend: ISpend;
}

export const TxVout = memo(function TxVout(props: TransactionVoutProps) {
    const {
        className,
        vout,
        index,
        expanded,
        spend,
    } = props;

    const { t } = useTranslation();
    const unspendable_types = [ 'op_return', 'provably_unspendable', 'fee' ];

    const wrapper = (children: ReactNode, description: ReactNode) => {
        return (
            <div className={classNames(cls.TxVout, className)}>
                <div className={cls.header}>
                    <HStack align="start">
                        <span className={cls.index}>{`#${index}`}</span>
                        <div className={cls.wrapper}>
                            {description || t('_nonstandard')}
                            <span className={cls.amount}>
                                {formatOutAmount(vout)}
                            </span>
                        </div>
                    </HStack>
                </div>
                {children}
            </div>
        )
    }

    const description = vout.scripthash_address ? linkToAddr(vout.scripthash_address)
        : vout.scriptpubkey_type ? vout.scriptpubkey_type.toUpperCase()
            : null;

    const body = (
        expanded ? <VStack gap="sm" className={classNames(cls.voutBody)}>
            {vout.scriptpubkey_type &&
                <div className={cls.voutBodyRow}>
                    <div>{t('_type')}</div>
                    <div>{vout.scriptpubkey_type.toUpperCase()}</div>
                </div>
            }

            <div className={cls.voutBodyRow}>
                <div>{t('_scripthash_hex')}</div>
                <div className="mono">{vout.scripthash}</div>
            </div>

            { vout.assetcommitment &&
                <div className={cls.voutBodyRow}>
                    <div>{t('_asset_commitment')}</div>
                    <div className="mono">{vout.assetcommitment}</div>
                </div>
            }

            { vout.asset &&
                <div className={cls.voutBodyRow}>
                    <div>{t('_asset_id')}</div>
                    <div className="mono"><Link to={`/asset/${vout.asset}`}>{vout.asset}</Link></div>
                </div>
            }

            { vout.valuecommitment &&
                <div className={cls.voutBodyRow}>
                    <div>{t('_value_commitment')}</div>
                    <div className="mono">{vout.valuecommitment}</div>
                </div>
            }

            { !unspendable_types.includes(vout.scriptpubkey_type) &&
                <div className={cls.voutBodyRow}>
                    <div>{t('_spending_tx')}</div>
                    <div>
                        {!spend
                            ? t('_loading')
                            : spend.spent
                                ? <span>
                                    {t('_spent_by')} <Link to={`/tx/${spend.txid}`} className="mono">{`${spend.txid}`}</Link> {' '}
                                    { spend.status ? spend.status.confirmed ? <span>{t('_in_block')} <Link to={`/block/${spend.status.block_hash}`}>#{spend.status.block_height}</Link></span> : `(${t('_unconfirmed')})` : `` }
                                </span>
                                : t('_unspent')
                        }
                    </div>
                </div>
            }
        </VStack> : null
    )

    return wrapper(
        body,
        description
    )
});
