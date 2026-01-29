import { memo, useCallback, useEffect } from "react";
import { useSelector } from "react-redux";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import classNames from "classnames";

import {
    BlockItemHeader,
    BlockItem,
    blocksFetch,
    getBlocksAdapterData
} from "@/entities/Block";

import { Button } from "@/shared/ui/Button";
import { VStack } from '@/shared/ui/Stack';

import { useAppDispatch } from "@/shared/lib/hooks";
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
    const { t } = useTranslation();
    const dispatch = useAppDispatch();
    const blocks = useSelector(getBlocksAdapterData.selectAll);

    useEffect(() => {
        dispatch(blocksFetch());
    }, []);

    const handleLoadMore = useCallback(() => {
        const lastBlock = blocks[blocks.length - 1];
        dispatch(blocksFetch(lastBlock.height - 1));
    }, [blocks, dispatch]);

    if (blocks.length === 0) {
        return (
            <VStack className={classNames(cls.Blocks, className)} justify='start'>
                <h3 className={cls.title}>{t('_loading')}</h3>
            </VStack>
        )
    }

    return (
        <VStack className={classNames(cls.Blocks, className)}>
            <h3 className={cls.title}>{t('_latest_blocks')}</h3>
            <BlockItemHeader/>
            {!isLoadMore && blocks?.slice(0, 5).map((block) => (
                <BlockItem block={block} key={block.id} />
            ))}
            {!isLoadMore && (
                <Link className={cls.viewMore} to="/blocks">
                    <span>{t('_view_more_blocks')}</span>
                    <ArrowRightIcon className={cls.svg}/>
                </Link>
            )}

            {isLoadMore && blocks?.map((block) => (
                <BlockItem block={block} key={block.id} />
            ))}

            {isLoadMore && (
                <Button
                    className={cls.loadMore}
                    onClick={handleLoadMore}
                    icon={<ExpandMoreIcon style={{ width: 24, height: 24 }} />}
                    iconPlacement='end'
                    size='large'
                >
                    <span>{t('_load_more')}</span>
                    {/*<ExpandMoreIcon />*/}
                </Button>
            )}
        </VStack>
    );
})
