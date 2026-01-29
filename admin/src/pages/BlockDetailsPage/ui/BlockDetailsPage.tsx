import { useEffect, useState } from 'react';
import { useSelector } from 'react-redux';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
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
    const { t } = useTranslation();
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
        return <div className={classNames(cls.BlockDetailsPage, 'container', className)}>{t('_loading')}</div>
    }

    if (!block) {
        return <div className={classNames(cls.BlockDetailsPage, 'container', className)}>{t('_block_not_found')}</div>
    }

    return (
        <div className={classNames(cls.BlockDetailsPage, 'container', className)}>
            <VStack gap="sm">
                <HStack>
                    <CubeIcon fill="#ffbb00" width="50px" height="50px"/>
                    <h1 className={cls.title}>{t('_block', { blockNumber: block.height })}</h1>
                </HStack>
                <Clipboard text={id as string} className={cls.clipboard}/>
                <HStack className={cls.blockLinks} justify="space-between">
                    <Button
                        onClick={clickOnBlock(block.previousblockhash)}
                        className={cls.prevBlockLink}
                        icon={<ArrowBackIcon/>}
                        type="dashed"
                    >
                        <span>{t('_previous')}</span>
                    </Button>

                    {status?.next_best && (
                        <Button
                            onClick={clickOnBlock(status.next_best)}
                            className={cls.nextBlockLink}
                            icon={<ArrowNextIcon/>}
                            iconPlacement="end"
                            type="dashed"
                        >
                            <span>{t('_next')}</span>
                        </Button>
                    )}
                </HStack>
            </VStack>

            <VStack className={cls.statsTable}>
                <Button
                    variant="outlined"
                    onClick={() => setExpanded(!expanded)}
                >
                    <span>{t('_details')}</span>
                    <ExpandMoreIcon fill="#FFBB00" className={expanded ? cls.expended : ''}/>
                </Button>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>{t('_height')}</span>
                    <Link to={`/blocks/${id}`}>{block.height}</Link>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>{t('_status')}</span>
                    <span>{t('_in_best_chain_confirmations', { confirmations : tipHeight - block.height + 1 })}</span>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>{t('_timestamp')}</span>
                    <Tooltip title={t(useUTC ? '_click_show_local_time' : '_click_show_utc_time')} placement="top">
                        <span onClick={() => setUseUTC(!useUTC)} style={{cursor: 'pointer'}}>{formatTime(block.timestamp, useUTC)}</span>
                    </Tooltip>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>{t('_size')}</span>
                    <span>{formatNumber(block.size / 1000)} KB</span>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>{t('_block_weight')}</span>
                    <span>{formatNumber(block.block_weight / 1000000000)} GW</span>
                </HStack>
                <HStack justify="space-between" className={cls.statsTableItem}>
                    <span>{t('_branch_units')}</span>
                    <span>{formatNumber(block.weight / 1000000000)} GW</span>
                </HStack>
                {expanded && (
                    <HStack justify="space-between" className={cls.statsTableItem}>
                        <span>{t('_merkle_root')}</span>
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
