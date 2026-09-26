"use client";

import { useEffect, useEffectEvent, useState, useSyncExternalStore } from "react";
import { describeError } from "./errors";

type State<T> = { data: T | null; error: string | null; loading: boolean; key: string };

const MAX_BACKOFF_MS = 60_000;
/** The wait before the next refresh: the interval, doubled for each consecutive failure, up to a minute (and never
    below the interval itself). */
export const refreshDelay = (intervalMs: number, failures: number) =>
  failures <= 0 ? intervalMs : Math.max(intervalMs, Math.min(intervalMs * 2 ** failures, MAX_BACKOFF_MS));

/** Runs `load` now and, when `intervalMs` > 0, again once each run has settled, so runs never overlap however slow one
    is. `load` resolves true on success; failures back off (refreshDelay). The returned stop aborts the run in flight
    through its signal and cancels the next one. */
export function startRefreshLoop(load: (signal: AbortSignal) => Promise<boolean>, intervalMs: number): () => void {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | null = null;
  let failures = 0;
  const tick = async () => {
    timer = null;
    const ok = await load(controller.signal).catch(() => false);
    if (controller.signal.aborted || intervalMs <= 0) return;
    failures = ok ? 0 : failures + 1;
    timer = setTimeout(tick, refreshDelay(intervalMs, failures));
  };
  void tick();
  return () => {
    controller.abort();
    if (timer) clearTimeout(timer);
  };
}

/** Loads `load()` whenever `key` or `version` changes, and on an interval when `intervalMs` is set (startRefreshLoop:
    no overlapping refreshes, backoff after failures). A new `key` is a different thing: data from an old key is never
    shown under a new one. A new `version` is the same thing read again now (a phase change, a new edition): like any
    refresh, and like a failed one, it keeps the previous data on screen until the new read lands. A superseded load is
    aborted through `signal` and its result dropped, so a slower, older response never overwrites a newer one. */
export function useAsync<T>(load: (signal: AbortSignal) => Promise<T>, key: string, intervalMs = 0, version = "") {
  const [state, setState] = useState<State<T>>({ data: null, error: null, loading: true, key });
  const [tick, setTick] = useState(0);
  const run = useEffectEvent(async (signal: AbortSignal): Promise<boolean> => {
    try {
      const data = await load(signal);
      if (!signal.aborted) setState({ data, error: null, loading: false, key });
      return true;
    } catch (error) {
      if (!signal.aborted) setState((s) => ({ data: s.key === key ? s.data : null, error: describeError(error), loading: false, key }));
      return false;
    }
  });
  useEffect(() => startRefreshLoop((signal) => run(signal), intervalMs), [key, version, tick, intervalMs]);
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
