import type { ReactNode } from 'react';
import classNames from 'classnames';

import cls from './TxInfoPanel.module.css';

export interface TxInfoRow {
    label: string;
    value: ReactNode;
}

interface TxInfoPanelProps {
    className?: string;
    description: string;
    icon?: ReactNode;
    title: string;
    rows: TxInfoRow[];
}

export const TxInfoPanel = ({ className, description, icon, title, rows }: TxInfoPanelProps) => (
    <div className={classNames(cls.TxInfoPanel, className)}>
        <div className={cls.summary}>
            {icon && <span className={cls.icon} aria-hidden="true">{icon}</span>}
            <div>
                <strong className={cls.title}>{title}</strong>
                <p className={cls.description}>{description}</p>
            </div>
        </div>
        <dl className={cls.facts}>
            {rows.map((row) => (
                <div className={cls.fact} key={row.label}>
                    <dt>{row.label}</dt>
                    <dd>{row.value}</dd>
                </div>
            ))}
        </dl>
    </div>
);
