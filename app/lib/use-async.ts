"use client";

import { useEffect, useEffectEvent, useState, useSyncExternalStore } from "react";
import { describeError } from "./errors";

type State<T> = { data: T | null; error: string | null; loading: boolean; key: string };

/** Loads `load()` whenever `key` changes (and every `intervalMs` when set). Previous data stays on screen while a
    refresh is in flight; data from an old key is never shown under a new one. */
export function useAsync<T>(load: () => Promise<T>, key: string, intervalMs = 0) {
  const [state, setState] = useState<State<T>>({ data: null, error: null, loading: true, key });
  const [tick, setTick] = useState(0);
  const run = useEffectEvent(async (alive: () => boolean) => {
    try {
      const data = await load();
      if (alive()) setState({ data, error: null, loading: false, key });
    } catch (error) {
      if (alive()) setState((s) => ({ data: s.key === key ? s.data : null, error: describeError(error), loading: false, key }));
    }
  });
  useEffect(() => {
    let live = true;
    void run(() => live);
    const id = intervalMs > 0 ? setInterval(() => void run(() => live), intervalMs) : null;
    return () => {
      live = false;
      if (id) clearInterval(id);
    };
  }, [key, tick, intervalMs]);
  const stale = state.key !== key;
  return { data: stale ? null : state.data, error: stale ? null : state.error, loading: stale || state.loading, refresh: () => setTick((t) => t + 1) };
}

/* A one-second clock as an external store, so countdowns can render without impure reads during render. */
let nowSnapshot = 0;
const clockListeners = new Set<() => void>();
let clock: ReturnType<typeof setInterval> | null = null;
function subscribeClock(listener: () => void) {
  clockListeners.add(listener);
  if (!clock) {
    nowSnapshot = Math.floor(Date.now() / 1000);
    clock = setInterval(() => {
      nowSnapshot = Math.floor(Date.now() / 1000);
      for (const l of clockListeners) l();
    }, 1000);
    queueMicrotask(listener);
  }
  return () => {
    clockListeners.delete(listener);
    if (clockListeners.size === 0 && clock) {
      clearInterval(clock);
      clock = null;
    }
  };
}
/** Unix seconds, ticking once a second on the client; 0 during server rendering and hydration. */
export const useNow = () => useSyncExternalStore(subscribeClock, () => nowSnapshot, () => 0);
