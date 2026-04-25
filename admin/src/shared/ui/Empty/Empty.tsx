import { memo } from 'react';
import { Empty as AntEmpty } from 'antd';
import classNames from 'classnames';

import cls from './Empty.module.css';

interface EmptyProps {
    className?: string;
}

export const Empty = memo(function Empty(props: EmptyProps) {
    const { className } = props;

    return (
        <AntEmpty
            className={classNames(cls.Empty, className)}
            image={AntEmpty.PRESENTED_IMAGE_SIMPLE}
            description={'No Data'}
        />
    )
})
