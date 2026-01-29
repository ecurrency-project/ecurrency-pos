import { Flex, type FlexProps } from '../Flex/Flex';
import type { JSX } from 'react';

type HStackProps<T extends keyof JSX.IntrinsicElements = 'div'> = Omit<FlexProps<T>, 'direction'>

export const HStack = <T extends keyof JSX.IntrinsicElements = 'div'>(props: HStackProps<T>) => (
    <Flex<T> {...props} direction="row" />
);
