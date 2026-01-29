import { useEffect, useRef } from 'react';

export const useRecurringTimeout = (callback: () => void, delay: number) => {
    const savedCallback = useRef<() => void>(callback);
    const timeoutRef = useRef<number>(null);

    useEffect(() => {
        savedCallback.current = callback;
    }, [callback]);

    useEffect(() => {
        function tick() {
            timeoutRef.current = setTimeout(() => {
                if (savedCallback.current) {
                    savedCallback.current();
                }

                if (delay !== null) {
                    tick();
                }
            }, delay)
        }

        if (delay !== null) {
            tick();

            return () => {
                if (timeoutRef.current) {
                    clearTimeout(timeoutRef.current)
                }
            }
        }

        return undefined;

    }, [delay]);
}
