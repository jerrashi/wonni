import { useCallback, useEffect, useRef } from "react";

// Trailing-edge debounce: waits `ms` after the *last* call before invoking
// `callback` with that call's most recent args. Always resets the timer on
// each new call rather than firing on the first one.
export function useDebouncedCallback(callback, ms) {
  const callbackRef = useRef(callback);
  const argsRef = useRef(null);
  const timerRef = useRef(null);

  callbackRef.current = callback;

  const clear = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const debounced = useCallback(
    (...args) => {
      argsRef.current = args;
      clear();
      timerRef.current = setTimeout(() => {
        timerRef.current = null;
        callbackRef.current(...argsRef.current);
      }, ms);
    },
    [clear, ms]
  );

  debounced.flush = useCallback(() => {
    if (!timerRef.current) return;
    clear();
    callbackRef.current(...argsRef.current);
  }, [clear]);

  debounced.cancel = useCallback(() => {
    clear();
    argsRef.current = null;
  }, [clear]);

  useEffect(() => clear, [clear]);

  return debounced;
}
