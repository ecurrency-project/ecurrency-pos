import classNames from "classnames";

import { TransactionsShort } from "@/widgets/TransactionsShort";

interface TransactionsPageProps {
    classname?: string;
}

const TransactionsPage = (props: TransactionsPageProps) => {
    const { classname } = props;

    return (
        <div className={classNames('container', classname)}>
            <TransactionsShort />
        </div>
    )
}

export default TransactionsPage;
