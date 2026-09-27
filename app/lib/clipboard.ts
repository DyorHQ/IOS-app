"use client";

import { useEffect, useState } from "react";

/** Copies `text` and resolves true only once the clipboard has taken it. It resolves false, never throws, when there is
    no clipboard API (an insecure context) or the write is refused (permission, an unfocused document), so a caller can
    confirm a copy only when it happened and say so when it did not. */
export async function copyText(text: string, clipboard: Pick<Clipboard, "writeText"> | undefined = typeof navigator === "undefined" ? undefined : navigator.clipboard): Promise<boolean> {
  if (!clipboard) return false;
  try {
    await clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

export type CopyState = "idle" | "copied" | "failed";
/** What every copy control says, so the feedback is the same wherever an address is copied. */
export const COPY_FEEDBACK: Record<Exclude<CopyState, "idle">, string> = { copied: "Address copied", failed: "Couldn't copy the address" };

/** The state of the last copy ("copied" or "failed"), back to "idle" after `resetMs`. */
export function useCopy(resetMs = 2000): [CopyState, (text: string) => Promise<boolean>] {
  const [state, setState] = useState<CopyState>("idle");
  useEffect(() => {
    if (state === "idle") return;
    const id = setTimeout(() => setState("idle"), resetMs);
    return () => clearTimeout(id);
  }, [state, resetMs]);
  const copy = async (text: string) => {
    const ok = await copyText(text);
    setState(ok ? "copied" : "failed");
    return ok;
  };
  return [state, copy];
}
