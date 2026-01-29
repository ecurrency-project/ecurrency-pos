import { Flex, type FlexProps } from '../Flex/Flex';
import type { JSX } from 'react';

type VStackProps<T extends keyof JSX.IntrinsicElements = 'div'> = Omit<FlexProps<T>, 'direction'>

export const VStack = <T extends keyof JSX.IntrinsicElements = 'div'>(props: VStackProps<T>) => {
    const { align = 'start' } = props;

    return <Flex {...props} direction="column" align={align} />;
};
