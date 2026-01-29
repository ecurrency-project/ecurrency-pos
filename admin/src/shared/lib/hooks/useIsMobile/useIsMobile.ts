import { useEffect, useState } from 'react'

export function useIsMobile(breakpoint: number = 768): boolean {

  const [isMobile, setIsMobile] = useState(() => {
    if (typeof window === 'undefined') {
      return false;
    }
    return window.innerWidth < breakpoint;
  });

  useEffect(() => {
    if (typeof window === 'undefined') {
      return;
    }

    const handleResize = () => {
      setIsMobile(window.innerWidth < breakpoint);
    };

    window.addEventListener('resize', handleResize);

    handleResize();

    return () => {
      window.removeEventListener('resize', handleResize);
    };
  }, [breakpoint]);

  return isMobile;
} 
