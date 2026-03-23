import { useCallback, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import classNames from 'classnames';
import { Tooltip } from 'antd';

import { Transactions } from '@/widgets/Transactions';

import { useGetBlockQuery, useGetBlockStatusQuery } from '@/entities/Block';
import { useGetTipHeightQuery } from '@/entities/TipHeight';
import { useGetTransactionsByBlockQuery } from '@/entities/Transaction';

import { HStack, VStack } from '@/shared/ui/Stack';
import { Button } from '@/shared/ui/Button';
import { Clipboard } from '@/shared/ui/Clipboard';

import { formatNumber, formatTime } from '@/shared/utils';
import { RouterPath } from '@/shared/config/router/router';
import { BYTES_PER_KB, UNITS_PER_GW } from '@/shared/const/const.ts';

import CubeIcon from '@/shared/assets/icons/cube.svg?react';
import ArrowBackIcon from '@/shared/assets/icons/arrow_back.svg?react';
import ArrowNextIcon from '@/shared/assets/icons/arrow_right.svg?react';
import ExpandMoreIcon from '@/shared/assets/icons/expand_more.svg?react';

import cls from './BlockDetailsPage.module.css';

interface BlockDetailsPageProps {
    className?: string
}

const BlockDetailsPage = (props: BlockDetailsPageProps) => {
    const { className } = props;
    const { id } = useParams<{ id: string }>();
    const [expanded, setExpanded] = useState<boolean>(false);
    const [useUTC, setUseUTC] = useState<boolean>(false);
    const navigate = useNavigate();

    const { data: block, isLoading: blockLoading, isFetching: blockFetching } = useGetBlockQuery({ id: id! }, { skip: !id });
    const { data: status } = useGetBlockStatusQuery({ id: id! }, { skip: !id });
    const { data: tipHeight = 0 } = useGetTipHeightQuery();
    const { data: transactionsByBlock, isLoading } = useGetTransactionsByBlockQuery({ blockHeight: id as string });

    const clickOnBlock = useCallback((blockId: string) => {
        navigate(`${RouterPath.blocks}/${blockId}`, { replace: true });
    }, [navigate]);

    if (blockLoading) {
        return <div className={classNames(cls.BlockDetailsPage, 'container', className)}>Loading...</div>
    }

    if (!block) {
        return <div className={classNames(cls.BlockDetailsPage, 'container', className)}>Block not found</div>
    }

    return (
        <div className={classNames(cls.BlockDetailsPage, 'container', className)}>
            <VStack gap="sm">
                <HStack>
                    <CubeIcon fill="#ffbb00" width="50px" height="50px"/>
                    <h1 className={cls.title}>Block { block.height }</h1>
                </HStack>
                <Clipboard text={id as string} className={cls.clipboard}/>
                <HStack className={cls.blockLinks} justify="space-between">
                    <Button
                        onClick={() => clickOnBlock(block.previousblockhash)}
                        className={cls.prevBlockLink}
                        icon={<ArrowBackIcon/>}
                        type="dashed"
                        disabled={block.previousblockhash === null}
                        loading={blockFetching}
                    >
                        <span>Previous</span>
                    </Button>

                    {status?.next_best && (
                        <Button
                            onClick={() => clickOnBlock(status.next_best!)}
                            className={cls.nextBlockLink}
                            icon={<ArrowNextIcon/>}
                            iconPlacement="end"
                            type="dashed"
                            loading={blockFetching}
                        >
                            <span>Next</span>
                        </Button>
                    )}
                </HStack>
            </VStack>

            <VStack className={cls.statsTable}>
                <Button
                    variant="outlined"
                    onClick={() => setExpanded(!expanded)}
                >
                    <span>Details</span>
                    <ExpandMoreIcon fill="#FFBB00" className={expanded ? cls.expended : ''}/>
                </Button>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Height</span>
                    <Link to={`/blocks/${id}`}>{block.height}</Link>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Status</span>
                    <span>In best chain (${tipHeight - block.height + 1} confirmations)</span>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Timestamp</span>
                    <Tooltip title={useUTC ? 'Show local time' : 'Show UTC time'} placement="top">
                        <span onClick={() => setUseUTC(!useUTC)} style={{cursor: 'pointer'}}>{formatTime(block.timestamp, useUTC)}</span>
                    </Tooltip>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Size</span>
                    <span>{formatNumber(block.size / BYTES_PER_KB)} KB</span>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Block weight</span>
                    <span>{formatNumber(block.block_weight / UNITS_PER_GW)} GW</span>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>Branch units</span>
                    <span>{formatNumber(block.weight / UNITS_PER_GW)} GW</span>
                </HStack>
                {expanded && (
                    <HStack justify="space-between" className={cls.statsTableItem}>
                        <span>Merkle root</span>
                        <span>{block.merkle_root}</span>
                    </HStack>
                )}
            </VStack>

            {!isLoading && <Transactions
                totalTxs={block.tx_count}
                isTitleVisible={true}
                className={cls.transactions}
                txs={transactionsByBlock}
            />}
        </div>
    )
}

export default BlockDetailsPage;
