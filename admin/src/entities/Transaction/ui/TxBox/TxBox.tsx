import { memo, useCallback, useState } from 'react';
import classNames from "classnames";

import { HStack, VStack } from "@/shared/ui/Stack";
import { formatSat } from '@/shared/utils';
import { useAssetLabel } from '@/shared/lib/network';

import ArrowForwardIcon from "@/shared/assets/icons/arrow_forward.svg?react";

import type { ITransaction } from '../../model/types/ITransaction.ts';
import { useLazyGetOutspendsQuery } from '../../api/transactionApi.ts';

import { TxItemFooter } from '../TxItemFooter/TxItemFooter.tsx';
import { TxVin } from "../TxVin/TxVin.tsx";
import { TxVout } from '../TxVout/TxVout.tsx';
import { TxBoxHeader } from '../TxBoxHeader/TxBoxHeader.tsx';
import { TxCoinbase } from '../TxCoinbase/TxCoinbase.tsx';
import { TxCoinbaseInfo } from '../TxCoinbaseInfo/TxCoinbaseInfo.tsx';
import { TxDowngradeInfo } from '../TxDowngradeInfo/TxDowngradeInfo.tsx';
import { TxSlashingInfo } from '../TxSlashingInfo/TxSlashingInfo.tsx';

import cls from './TxBox.module.css';

interface TxBoxProps {
    className?: string
    tx: ITransaction
    highlightAddress?: string;
}

export const TxBox = memo(function TxBox(props: TxBoxProps) {
    const {
        className,
        tx,
        highlightAddress,
    } = props;

    const [expanded, setExpanded] = useState<boolean>(false);
    const [triggerOutspends, { data: spends }] = useLazyGetOutspendsQuery();
    const assetLabel = useAssetLabel();

    const toggleExpanded = useCallback(() => {
        setExpanded((prev) => {
            if (!prev) {
                triggerOutspends({ txid: tx.txid });
            }
            return !prev;
        });
    }, [triggerOutspends, tx.txid]);

    return (
        <VStack className={classNames(cls.TxBox, className)} id="transaction-box" gap="sm">
            <TxBoxHeader
                txid={tx.txid}
                toggleExpanded={toggleExpanded}
                expanded={expanded}
                className={cls.header}
                date={tx.status.block_time}
                fee={tx.fee}
                txType={tx.tx_type}
            />
            {tx.coinbase_info && <TxCoinbaseInfo info={tx.coinbase_info} className={cls.infoPanel} />}
            {tx.downgrade_info && <TxDowngradeInfo info={tx.downgrade_info} className={cls.infoPanel} />}
            {tx.tx_type === 'slashing' && (
                <TxSlashingInfo
                    fine={tx.fee}
                    inputCount={tx.vin.length}
                    outputCount={tx.vout.length}
                    className={cls.infoPanel}
                />
            )}
            <HStack className={cls.wrapper} gap='xs'>
                <VStack className={cls.vins} gap='xs'>
                    {tx.is_coinbase && !tx.vin.length && <TxCoinbase key="coinbase" index={0} value={tx.value}/>}
                    {tx.vin.map((v, index) => (<TxVin vin={v} key={v.txid} index={index} expanded={expanded} highlightAddress={highlightAddress} txType={tx.tx_type}/> ))}
                </VStack>
                <div className="ins-and-outs_spacer">
                    <ArrowForwardIcon fill='#1187C1' className={cls.arrow}/>
                </div>
                <VStack className={cls.vouts} gap='xs'>
                    {tx.vout.length === 0 && (
                        <div className={cls.noOutputs}>
                            <span className={cls.emptyIndex}>#—</span>
                            <div className={cls.emptyOutputBody}>
                                <span className={cls.emptyOutputTitle}>
                                    {tx.tx_type === 'burn' ? 'Permanently burned' : 'No outputs'}
                                </span>
                                {tx.tx_type === 'burn' && (
                                    <>
                                        <span className={cls.emptyOutputAmount}>{formatSat(tx.value, assetLabel)}</span>
                                        <span className={cls.emptyOutputDescription}>No spendable output was created</span>
                                    </>
                                )}
                            </div>
                        </div>
                    )}
                    {tx.vout.map((v, index) => (
                        <TxVout
                            vout={v}
                            key={v.scripthash}
                            index={index}
                            expanded={expanded}
                            spend={spends?.[index]}
                            highlightAddress={highlightAddress}
                        />
                    ))}
                </VStack>
            </HStack>
            <TxItemFooter
                txStatus={tx.status}
                tipHeight={0}
                vin={tx.vin}
                vout={tx.vout}
                className={cls.footer}
            />
        </VStack>
    )
})
