import classNames from "classnames";

import { Blocks } from "@/widgets/Blocks";

import cls from "./BlocksPage.module.css";

interface BlocksPageProps {
    classname?: string;
}

const BlocksPage = (props: BlocksPageProps) => {
    const { classname } = props;

    return (
        <div className={classNames(cls.BlocksPage, 'container', classname)}>
            <Blocks isLoadMore />
        </div>
    )
}

export default BlocksPage;
