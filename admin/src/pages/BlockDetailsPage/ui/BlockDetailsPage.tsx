import { useEffect, useState } from 'react';
import { useSelector } from 'react-redux';
import { Link, useNavigate, useParams } from 'react-router-dom';
import classNames from 'classnames';
import axios from 'axios';
import { Tooltip } from 'antd';

import type { StateSchema } from '@/app/providers/StoreProvider';

import { Transactions } from '@/widgets/Transactions';

import { getBlocksAdapterData, getBlocksLoading, blockOneFetch, type BlocksStatus } from '@/entities/Block';
import { getTipHeight } from '@/entities/TipHeight';
import { useGetTransactionsByBlockQuery } from '@/entities/Transaction';

import { HStack, VStack } from '@/shared/ui/Stack';
import { Button } from '@/shared/ui/Button';
import { Clipboard } from '@/shared/ui/Clipboard';

import { formatNumber, formatTime } from '@/shared/utils';
import { useAppDispatch } from '@/shared/lib/hooks';
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
    const [status, setStatus] = useState<BlocksStatus | undefined>(undefined);
    const [expanded, setExpanded] = useState<boolean>(false);
    const [useUTC, setUseUTC] = useState<boolean>(false);
    const dispatch = useAppDispatch();
    const navigate = useNavigate();

    const block = useSelector((state: StateSchema) => getBlocksAdapterData.selectById(state, id as string));
    const blockLoading = useSelector(getBlocksLoading);
    const tipHeight = useSelector(getTipHeight);
    const { data: transactionsByBlock, isLoading } = useGetTransactionsByBlockQuery({ blockHeight: id as string });

    useEffect(() => {
        if (!id) return;

        if (!block) {
            dispatch(blockOneFetch(id));
        }

        axios.get<BlocksStatus>(`/api/block/${id}/status`)
            .then((response) => {
                setStatus(response.data);
            })
            .catch((error) => {
                console.error(error);
            });
    }, [dispatch, id]);

    const clickOnBlock = (id: string) => () => {
        navigate(`${RouterPath.blocks}/${id}`);
    }

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
                        onClick={clickOnBlock(block.previousblockhash)}
                        className={cls.prevBlockLink}
                        icon={<ArrowBackIcon/>}
                        type="dashed"
                    >
                        <span>Previous</span>
                    </Button>

                    {status?.next_best && (
                        <Button
                            onClick={clickOnBlock(status.next_best)}
                            className={cls.nextBlockLink}
                            icon={<ArrowNextIcon/>}
                            iconPlacement="end"
                            type="dashed"
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
