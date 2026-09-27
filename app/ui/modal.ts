"use client";

import { useEffect, type RefObject } from "react";

/* Modal overlays: the app's sheets, menu and phone-width studio, and the swap token picker. They are drawn inside the
   device frame, so they can't be native <dialog>s in the top layer; this gives them the same behaviour. While one is
   open everything outside it is inert (Tab, a screen reader's virtual cursor and pointer clicks stay inside), focus
   moves into it, and when it closes focus returns to where it was. A live region that is itself one of the inerted
   siblings (the toast) is left alone and still announced. One nested inside inerted content (a screen's transaction
   status) is silenced with it, so a status that settles there speaks through announce(), the page-level region. */

const SKIP = new Set(["SCRIPT", "STYLE", "LINK", "META", "TEMPLATE", "NOSCRIPT"]);
const isLiveRegion = (el: Element) => el.hasAttribute("aria-live") || ["status", "alert", "log"].includes(el.getAttribute("role") ?? "");
const FOCUSABLE = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** Makes every element outside `overlay` (the other children of each of its ancestors) inert, except live regions and
    elements that already are; returns the undo, which touches only what it changed. */
export function inertOutside(overlay: Element): () => void {
  const changed: Element[] = [];
  for (let node: Element = overlay; node.parentElement && node !== document.body; node = node.parentElement) {
    for (const sibling of Array.from(node.parentElement.children)) {
      if (sibling === node || SKIP.has(sibling.tagName) || isLiveRegion(sibling) || sibling.hasAttribute("inert")) continue;
      sibling.setAttribute("inert", "");
      changed.push(sibling);
    }
  }
  return () => changed.forEach((el) => el.removeAttribute("inert"));
}

let announcer: HTMLElement | null = null;
let pendingAnnouncement: ReturnType<typeof setTimeout> | null = null;

/** The page-level polite live region: a direct child of <body>, so no overlay makes it inert. It is created empty, the
    first time something may need it, because a region that appears together with its first message is often not
    announced. */
export function ensureAnnouncer(): HTMLElement | null {
  if (typeof document === "undefined") return null;
  if (announcer?.isConnected) return announcer;
  announcer = document.createElement("div");
  announcer.setAttribute("role", "status");
  announcer.setAttribute("aria-live", "polite");
  announcer.setAttribute("class", "sr-only");
  document.body.appendChild(announcer);
  return announcer;
}

/** Says `text` through the page-level live region. The text is set a moment after the region is emptied, so the same
    message twice is still announced; a newer message within that moment replaces an older one. */
export function announce(text: string) {
  const region = ensureAnnouncer();
  if (!region) return;
  if (pendingAnnouncement) clearTimeout(pendingAnnouncement);
  region.textContent = "";
  pendingAnnouncement = setTimeout(() => {
    pendingAnnouncement = null;
    region.textContent = text;
  }, 100);
}

/** While `open`, `ref`'s element is modal: the rest of the page is inert and focus starts on `initialFocus()` (default:
    the first focusable element inside). On close, focus goes back to the element that had it when the overlay opened,
    if that is still on the page and usable. */
export function useModal(ref: RefObject<HTMLElement | null>, open: boolean, initialFocus?: () => HTMLElement | null | undefined) {
  useEffect(() => {
    const overlay = ref.current;
    if (!open || !overlay) return;
    const opener = document.activeElement instanceof HTMLElement && document.activeElement !== document.body ? document.activeElement : null;
    const restore = inertOutside(overlay);
    (initialFocus?.() ?? overlay.querySelector<HTMLElement>(FOCUSABLE) ?? overlay).focus({ preventScroll: true });
    return () => {
      restore();
      if (opener?.isConnected && !opener.closest("[inert]") && !opener.matches(":disabled")) opener.focus({ preventScroll: true });
    };
    // Only opening and closing matter; initialFocus is read once, when the overlay opens.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, ref]);
}
