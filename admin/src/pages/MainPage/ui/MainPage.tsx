import classNames from "classnames";

import { Blocks } from "@/widgets/Blocks";
import { TransactionsShort } from "@/widgets/TransactionsShort";

import cls from "./MainPage.module.css";

interface MainPageProps {
    classname?: string;
}

const MainPage = (props: MainPageProps) => {
    const { classname } = props;

    return (
        <div className={classNames(cls.MainPage, 'container', classname)}>
            <Blocks />
            <TransactionsShort />
        </div>
    )
}

export default MainPage;
