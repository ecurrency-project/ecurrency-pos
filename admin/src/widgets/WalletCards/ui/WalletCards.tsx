import type { IMyAddress } from '@/entities/MyAddress';

import { Empty } from '@/shared/ui/Empty';

import { WalletCard } from './WalletCard';

import cls from './WalletCards.module.css';

interface WalletCardsProps {
    addresses?: IMyAddress[];
    editingAddresses: Set<string>;
    onStakedChange: (address: string, staked: boolean) => void;
}

export const WalletCards = (props: WalletCardsProps) => {
    const { addresses, editingAddresses, onStakedChange } = props;

    if (!addresses?.length) {
        return <Empty />;
    }

    return (
        <div className={cls.WalletCards}>
            {addresses.map((myAddress) => (
                <WalletCard
                    key={myAddress.address}
                    myAddress={myAddress}
                    stakedLoading={editingAddresses.has(myAddress.address)}
                    onStakedChange={onStakedChange}
                />
            ))}
        </div>
    );
};
