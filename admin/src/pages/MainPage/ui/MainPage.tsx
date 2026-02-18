import classNames from "classnames";

import { Blocks } from "@/widgets/Blocks";
import { Peers } from "@/widgets/Peers";
import { TransactionsShort } from "@/widgets/TransactionsShort";

import { ChainStatusInfo } from '@/entities/ChainStatus';

import cls from "./MainPage.module.css";

interface MainPageProps {
    classname?: string;
}

const MainPage = (props: MainPageProps) => {
    const { classname } = props;

    return (
        <div className={classNames(cls.MainPage, 'container', classname)}>
            <ChainStatusInfo />
            <Peers />
            <Blocks />
            <TransactionsShort />
        </div>
    )
}

export default MainPage;
