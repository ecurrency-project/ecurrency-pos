import { useLocation } from 'react-router-dom';
import classNames from "classnames";

import cls from "./NotFoundPage.module.css";

interface NotFoundPageProps {
    classname?: string;
}

const NotFoundPage = (props: NotFoundPageProps) => {
    const { classname } = props;
    const location = useLocation();

    return <div className={classNames(cls.NotFoundPage, classname)}>
        <h1 className={cls.title}>{location?.state?.query ? location.state.query : 'Not found page'} </h1>
    </div>
}

export default NotFoundPage;
