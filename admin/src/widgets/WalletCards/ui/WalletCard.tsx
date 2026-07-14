import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Dropdown, type MenuProps, Modal, Popover, Switch, Tooltip } from 'antd';

import { useGetAddressQuery } from '@/entities/Address';
import { TokenChip } from '@/entities/Token';
import type { IMyAddress } from '@/entities/MyAddress';

import { Button } from '@/shared/ui/Button';
import { QrCode } from '@/shared/ui/QrCode';
import { Clipboard } from '@/shared/ui/Clipboard';
import { NativeCoinIcon } from '@/shared/ui/NativeCoinIcon';
import { VStack } from '@/shared/ui/Stack';
import { formatNumber } from '@/shared/utils';
import { sat2btc } from '@/shared/lib/fmtbtc';
import { brand } from '@/brand';
import {
    BALANCE_POLL_INTERVAL,
    CLIPBOARD_TOOLTIP_TIMEOUT,
    COIN_DECIMALS,
    WALLET_TOKEN_CHIP_LIMIT,
} from '@/shared/const/const';
import { RouterPath, RoutersApp } from '@/shared/config/router/router';

import SendArrowIcon from '@/shared/assets/icons/send_arrow.svg?react';
import ReceiveArrowIcon from '@/shared/assets/icons/receive_arrow.svg?react';
import MoreDotsIcon from '@/shared/assets/icons/more_dots.svg?react';
import ChevronDownIcon from '@/shared/assets/icons/chevron_down.svg?react';
import HistoryClockIcon from '@/shared/assets/icons/history_clock.svg?react';
import TokenHexIcon from '@/shared/assets/icons/token_hex.svg?react';
import CopyOutlineIcon from '@/shared/assets/icons/copy_outline.svg?react';
import QrOutlineIcon from '@/shared/assets/icons/qr_outline.svg?react';

import cls from './WalletCard.module.css';

interface WalletCardProps {
    myAddress: IMyAddress;
    stakedLoading: boolean;
    onStakedChange: (address: string, staked: boolean) => void;
}

const shortAddress = (address: string) =>
    address.length > 14 ? `${address.slice(0, 6)}…${address.slice(-4)}` : address;

export const WalletCard = (props: WalletCardProps) => {
    const { myAddress, stakedLoading, onStakedChange } = props;

    const navigate = useNavigate();
    const [copied, setCopied] = useState(false);
    const [receiveOpen, setReceiveOpen] = useState(false);

    const address = myAddress.address;
    const { data: addressInfo, isLoading: isInfoLoading } = useGetAddressQuery({ id: address }, {
        pollingInterval: BALANCE_POLL_INTERVAL,
    });

    const balanceSat = addressInfo
        ? addressInfo.chain_stats.funded_txo_sum - addressInfo.chain_stats.spent_txo_sum
        : 0;
    const tokens = Object.entries(addressInfo?.tokens ?? {});
    const visibleTokens = tokens.slice(0, WALLET_TOKEN_CHIP_LIMIT);
    const overflowCount = tokens.length - visibleTokens.length;

    const handleCopy = () => {
        navigator.clipboard?.writeText(address).then(() => {
            setCopied(true);
            setTimeout(() => setCopied(false), CLIPBOARD_TOOLTIP_TIMEOUT);
        });
    };

    const goToSend = () => {
        navigate(RouterPath[RoutersApp.SEND_TRANSACTION], { state: { address } });
    };

    const handleSendToken = (tokenId: string) => {
        navigate(RouterPath[RoutersApp.SEND_TRANSACTION], { state: { address, tokenId } });
    };

    const menuItems: MenuProps['items'] = [
        {
            key: 'history',
            label: 'History',
            icon: <HistoryClockIcon className={cls.menuIcon} />,
            onClick: () => navigate(RouterPath[RoutersApp.ADDRESS].replace(':id', address)),
        },
    ];

    return (
        <div className={cls.WalletCard}>
            <div className={cls.head}>
                <div className={cls.meta}>
                    <h3 className={cls.name} title={address} translate="no">{shortAddress(address)}</h3>
                    <div className={cls.pills}>
                        <span className={cls.addrPill}>
                            <Tooltip title="Copied!" open={copied}>
                                <button
                                    type="button"
                                    className={cls.iconBtn}
                                    aria-label="Copy address"
                                    onClick={handleCopy}
                                >
                                    <CopyOutlineIcon />
                                </button>
                            </Tooltip>
                            <button
                                type="button"
                                className={cls.iconBtn}
                                aria-label="Receive funds"
                                onClick={() => setReceiveOpen(true)}
                            >
                                <QrOutlineIcon />
                            </button>
                        </span>
                        <span className={cls.stakePill}>
                            <span className={cls.stakeLabel}>Staking</span>
                            <Switch
                                size="small"
                                checked={!!myAddress.staked}
                                loading={stakedLoading}
                                onChange={(checked) => onStakedChange(address, checked)}
                            />
                        </span>
                    </div>
                </div>
                <div className={cls.actions}>
                    <Button
                        type="primary"
                        className={cls.btn}
                        icon={<SendArrowIcon className={cls.btnIcon} />}
                        onClick={goToSend}
                    >
                        <span className={cls.btnLabel}>Send</span>
                    </Button>
                    <Button
                        className={cls.btn}
                        icon={<ReceiveArrowIcon className={cls.btnIcon} />}
                        onClick={() => setReceiveOpen(true)}
                    >
                        <span className={cls.btnLabel}>Receive</span>
                    </Button>
                    <Dropdown menu={{ items: menuItems }} trigger={['click']} rootClassName={cls.menu}>
                        <Button
                            className={cls.btnSquare}
                            icon={<MoreDotsIcon className={cls.btnIconMore} />}
                            aria-label="More"
                        />
                    </Dropdown>
                </div>
            </div>

            <div className={cls.balanceRow}>
                <NativeCoinIcon className={cls.coin} />
                {isInfoLoading ? (
                    <span className={cls.loading}>Loading...</span>
                ) : (
                    <div className={cls.balance}>
                        <span className={cls.amount} translate="no">
                            {formatNumber(sat2btc(balanceSat), COIN_DECIMALS)}
                        </span>
                        <span className={cls.unit}>{brand.assetLabel}</span>
                        <span className={cls.feePill}>Native · fees</span>
                    </div>
                )}
            </div>

            <div className={cls.tokensBlock}>
                {tokens.length > 0 ? (
                    <>
                        <div className={cls.tokensHead}>
                            <span className={cls.tokensTitle}>Tokens</span>
                            <span className={cls.tokensCount} translate="no">{tokens.length}</span>
                        </div>
                        <div className={cls.chips}>
                            {visibleTokens.map(([tokenId, amount]) => (
                                <TokenChip
                                    key={tokenId}
                                    tokenId={tokenId}
                                    amount={amount}
                                    onSendToken={handleSendToken}
                                />
                            ))}
                            {overflowCount > 0 && (
                                <Popover
                                    trigger="click"
                                    placement="bottomLeft"
                                    arrow={false}
                                    classNames={{ root: cls.tokensPopover }}
                                    content={
                                        <div className={cls.overflowPanel}>
                                            <div className={cls.overflowHead}>
                                                <span className={cls.overflowName} title={address} translate="no">
                                                    {shortAddress(address)}
                                                </span>
                                                <span className={cls.tokensCount} translate="no">
                                                    {`${tokens.length} tokens`}
                                                </span>
                                            </div>
                                            <div className={cls.overflowList}>
                                                {tokens.map(([tokenId, amount]) => (
                                                    <TokenChip
                                                        key={tokenId}
                                                        tokenId={tokenId}
                                                        amount={amount}
                                                        variant="row"
                                                        onSendToken={handleSendToken}
                                                    />
                                                ))}
                                            </div>
                                        </div>
                                    }
                                >
                                    <button type="button" className={cls.moreChip}>
                                        {`+${overflowCount} more`}
                                        <ChevronDownIcon className={cls.moreChev} />
                                    </button>
                                </Popover>
                            )}
                        </div>
                    </>
                ) : (
                    <span className={cls.noTokens}>
                        <TokenHexIcon className={cls.noTokensIcon} aria-hidden="true" />
                        No tokens yet — assets you receive will appear here.
                    </span>
                )}
            </div>

            <Modal
                open={receiveOpen}
                onCancel={() => setReceiveOpen(false)}
                footer={null}
                title="Receive funds"
            >
                <VStack gap="md" align="center" className={cls.receiveBody}>
                    <QrCode value={address} />
                    <Clipboard text={address} />
                </VStack>
            </Modal>
        </div>
    );
};
