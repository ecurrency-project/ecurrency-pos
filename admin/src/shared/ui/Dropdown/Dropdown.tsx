import type { ComponentProps } from 'react';
import { Dropdown as AntDropdown, type MenuProps } from 'antd';

interface DropdownProps extends ComponentProps<typeof AntDropdown> {
    className?: string;
    items: MenuProps['items'];
    isSelectable?: boolean;
    defaultSelectedKeys?: string[];
    destroyPopupOnHide?: boolean;
}

export const Dropdown = (props: DropdownProps) => {
    const { className, items, isSelectable, defaultSelectedKeys, destroyPopupOnHide, children } = props;

    return <AntDropdown className={className} menu={{ items, selectable: isSelectable, defaultSelectedKeys }} destroyPopupOnHide={destroyPopupOnHide}>
        {children}
    </ AntDropdown>;
}
