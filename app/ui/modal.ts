"use client";

import { useEffect, type RefObject } from "react";

/* Modal overlays: the app's sheets, menu and phone-width studio, and the swap token picker. They are drawn inside the
   device frame, so they can't be native <dialog>s in the top layer; this gives them the same behaviour. While one is
   open everything outside it is inert (Tab, a screen reader's virtual cursor and pointer clicks stay inside), focus
   moves into it, and when it closes focus returns to where it was. Live regions are left alone, so a toast or a status
   message outside the overlay is still announced. */

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
