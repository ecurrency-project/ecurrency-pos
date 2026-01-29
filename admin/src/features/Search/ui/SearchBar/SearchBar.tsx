import { type ChangeEvent, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { Input } from 'antd';
import classNames from "classnames";

import { RouterPath } from '@/shared/config/router/router';

import QRCodeIcon from '@/shared/assets/icons/qrcode.svg?react';

import { searchRequest } from '../../lib/searchRequest';

import cls from "./SearchBar.module.css";


interface SearchBarProps {
classname?: string;
}

export const SearchBar = (props: SearchBarProps) => {
    const { classname } = props;
    const { t } = useTranslation();
    const [query, setQuery] = useState('');
    const [isLoaded, setIsLoaded] = useState(false);

    const navigate = useNavigate();

    const handleChange = (e: ChangeEvent<HTMLInputElement>) => {
        setQuery(e.target.value);
    }

    const handleSearch = async () => {
        if (isLoaded || query.trim() === '') {
            return;
        }
        setIsLoaded(true)
        const result = await searchRequest(query);
        setIsLoaded(false)
        navigate(result ? result : '/not-found', { state: { query: 'No results found' } });
    }

    const suffix = (
        <Link to={RouterPath.qr_scanner} className={cls.qrcodeLink}>
            <QRCodeIcon />
        </Link>
    )

    return (
        <div className={classNames(cls.SearchBar, classname)}>
            <Input.Search
                placeholder={t('Search for block height, hash, transaction, or address')}
                enterButton
                value={query}
                onChange={handleChange}
                onSearch={handleSearch}
                onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                        handleSearch();
                    }
                }}
                size="large"
                suffix={suffix}
            />
        </div>
    );
}
