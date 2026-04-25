import { memo, useCallback, useState } from 'react';
import classNames from "classnames";

import { HStack, VStack } from "@/shared/ui/Stack";

import ArrowForwardIcon from "@/shared/assets/icons/arrow_forward.svg?react";

import type { ITransaction } from '../../model/types/ITransaction.ts';
import { useLazyGetOutspendsQuery } from '../../api/transactionApi.ts';

import { TxItemFooter } from '../TxItemFooter/TxItemFooter.tsx';
import { TxVin } from "../TxVin/TxVin.tsx";
import { TxVout } from '../TxVout/TxVout.tsx';
import { TxBoxHeader } from '../TxBoxHeader/TxBoxHeader.tsx';
import { TxCoinbase } from '../TxCoinbase/TxCoinbase.tsx';

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
            />
            <HStack className={cls.wrapper} gap='xs'>
                <VStack className={cls.vins} gap='xs'>
                    {tx.is_coinbase && !tx.vin.length && <TxCoinbase key="coinbase" index={0} value={tx.value}/>}
                    {tx.vin.map((v, index) => (<TxVin vin={v} key={v.txid} index={index} expanded={expanded} highlightAddress={highlightAddress}/> ))}
                </VStack>
                <div className="ins-and-outs_spacer">
                    <ArrowForwardIcon fill='#1187C1' className={cls.arrow}/>
                </div>
                <VStack className={cls.vouts} gap='xs'>
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
