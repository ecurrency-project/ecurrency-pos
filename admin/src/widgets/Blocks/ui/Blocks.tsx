import { memo, useCallback, useEffect, useState } from 'react';
import { Link } from "react-router-dom";
import { Card, Skeleton } from 'antd';
import classNames from "classnames";

import {
    BlockItemHeader,
    BlockItem,
    useGetBlocksQuery,
    useLazyGetBlocksQuery,
    type IBlock
} from '@/entities/Block';

import { Button } from "@/shared/ui/Button";
import { LATEST_BLOCKS_DISPLAY_COUNT } from '@/shared/const/const.ts';

import ArrowRightIcon from "@/shared/assets/icons/arrow_right.svg?react";
import ExpandMoreIcon from "@/shared/assets/icons/expand_more.svg?react";

import cls from './Blocks.module.css'

interface BlocksProps {
    className?: string;
    isLoadMore?: boolean;
}

export const Blocks = memo(function Blocks(props: BlocksProps) {
    const {
        className,
        isLoadMore = false
    } = props;
    const { data: initialBlocks, isLoading } = useGetBlocksQuery();
    const [triggerLoadMore] = useLazyGetBlocksQuery();
    const [extraBlocks, setExtraBlocks] = useState<IBlock[]>([]);
    const [loadingMore, setLoadingMore] = useState(false);

    useEffect(() => {
        setExtraBlocks([]);
    }, [initialBlocks]);

    const allBlocks = [...(initialBlocks ?? []), ...extraBlocks];

    const handleLoadMore = useCallback(() => {
        const lastBlock = allBlocks[allBlocks.length - 1];
        if (!lastBlock || loadingMore) return;
        setLoadingMore(true);
        triggerLoadMore(lastBlock.height - 1)
            .unwrap()
            .then((moreBlocks) => {
                setExtraBlocks((prev) => [...prev, ...moreBlocks]);
            })
            .finally(() => {
                setLoadingMore(false);
            });
    }, [allBlocks, triggerLoadMore, loadingMore]);

    if (isLoading || allBlocks.length === 0) {
        return (
            <Card className={classNames(cls.Blocks, className)}>
                <div className={cls.header}>
                    <span className={cls.headerTitle}>Latest blocks</span>
                </div>
                <Skeleton active paragraph={{ rows: 5 }} />
            </Card>
        )
    }

    return (
        <Card className={classNames(cls.Blocks, className)}>
            <div className={cls.header}>
                <span className={cls.headerTitle}>Latest blocks</span>
            </div>
            <BlockItemHeader/>
            {!isLoadMore && allBlocks.slice(0, LATEST_BLOCKS_DISPLAY_COUNT).map((block) => (
                <BlockItem block={block} key={block.id} />
            ))}
            {!isLoadMore && (
                <Link className={cls.viewMore} to="/blocks">
                    <span>View more blocks</span>
                    <ArrowRightIcon className={cls.svg}/>
                </Link>
            )}

            {isLoadMore && allBlocks.map((block) => (
                <BlockItem block={block} key={block.id} />
            ))}

            {isLoadMore && (
                <Button
                    className={cls.loadMore}
                    onClick={handleLoadMore}
                    loading={loadingMore}
                    icon={<ExpandMoreIcon style={{ width: 24, height: 24 }} />}
                    iconPlacement='end'
                    size='large'
                >
                    <span>Load more</span>
                </Button>
            )}
        </Card>
    );
})
