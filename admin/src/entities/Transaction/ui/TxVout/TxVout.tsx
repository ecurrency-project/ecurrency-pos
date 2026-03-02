import { memo, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import classNames from "classnames";

import { HStack, VStack } from '@/shared/ui/Stack';
import { moveDecimalPoint } from '@/shared/lib/moveDecimalPoint';

import type { ISpend, Vout } from '../../model/types/ITransaction.ts';

import { formatOutAmount, linkToAddr } from '../utils.tsx';

import cls from './TxVout.module.css';

interface TransactionVoutProps {
    className?: string
    vout: Vout;
    index?: number
    expanded?: boolean;
    spend: ISpend;
    highlightAddress?: string;
}

export const TxVout = memo(function TxVout(props: TransactionVoutProps) {
    const {
        className,
        vout,
        index,
        expanded,
        spend,
        highlightAddress,
    } = props;

    const unspendable_types = [ 'op_return', 'provably_unspendable', 'fee' ];

    const isHighlighted = highlightAddress && vout.scripthash_address === highlightAddress;

    const wrapper = (children: ReactNode, description: ReactNode) => {
        return (
            <div className={classNames(cls.TxVout, className, { [cls.highlighted]: isHighlighted })}>
                <div className={cls.header}>
                    <HStack align="start">
                        <span className={cls.index}>{`#${index}`}</span>
                        <div className={cls.wrapper}>
                            {description ||'Nonstandard'}
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
                    <div>Type</div>
                    <div>{vout.scriptpubkey_type.toUpperCase()}</div>
                </div>
            }

            <div className={cls.voutBodyRow}>
                <div>script hash (hex)</div>
                <div className="mono">{vout.scripthash}</div>
            </div>

            { vout.assetcommitment &&
                <div className={cls.voutBodyRow}>
                    <div>Asset commitment</div>
                    <div className="mono">{vout.assetcommitment}</div>
                </div>
            }

            { vout.asset &&
                <div className={cls.voutBodyRow}>
                    <div>Asset ID</div>
                    <div className="mono"><Link to={`/asset/${vout.asset}`}>{vout.asset}</Link></div>
                </div>
            }

            { vout.token_id &&
                <div className={cls.voutBodyRow}>
                    <div>token id</div>
                    <div className="mono">{vout.token_id}</div>
                </div>
            }

            { vout.token_amount !== undefined && vout.token_amount !== 0 &&
                <div className={cls.voutBodyRow}>
                    <div>token amount</div>
                    <div className="mono">{moveDecimalPoint(vout.token_amount, -vout.token_decimals)}</div>
                </div>
            }

            { vout.token_permissions !== undefined &&
                <div className={cls.voutBodyRow}>
                    <div>token permissions</div>
                    <div className="mono">{vout.token_permissions}</div>
                </div>
            }

            { vout.valuecommitment &&
                <div className={cls.voutBodyRow}>
                    <div>Value commitment</div>
                    <div className="mono">{vout.valuecommitment}</div>
                </div>
            }

            { !unspendable_types.includes(vout.scriptpubkey_type) &&
                <div className={cls.voutBodyRow}>
                    <div>Spending Tx</div>
                    <div>
                        {!spend
                            ? 'Loading...'
                            : spend.spent
                                ? <span>
                                    Spent by <Link to={`/tx/${spend.txid}`} className="mono">{`${spend.txid}`}</Link> {' '}
                                    { spend.status ? spend.status.confirmed ? <span>in block <Link to={`/block/${spend.status.block_hash}`}>#{spend.status.block_height}</Link></span> : `(Unconfirmed)` : `` }
                                </span>
                                : 'Unspent'
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
