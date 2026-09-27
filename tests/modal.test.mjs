import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/ui/modal.ts: while an overlay is open everything outside it is inert, except live regions among the inerted
   siblings (a toast must still be announced) and elements that already were inert (React owns those); closing undoes
   exactly what opening changed. A status nested inside inerted content is silenced with it, which is why the page-level
   announcer exists. */

class El {
  constructor(tagName, attrs = {}, children = []) {
    this.tagName = tagName;
    this.attrs = new Map(Object.entries(attrs));
    this.parentElement = null;
    this.children = [];
    for (const c of children) this.append(c);
  }
  append(child) { child.parentElement = this; this.children.push(child); return child; }
  appendChild(child) { return this.append(child); }
  get isConnected() { return this.tagName === "HTML" || (this.parentElement?.isConnected ?? false); }
  hasAttribute(n) { return this.attrs.has(n); }
  getAttribute(n) { return this.attrs.has(n) ? this.attrs.get(n) : null; }
  setAttribute(n, v) { this.attrs.set(n, v); }
  removeAttribute(n) { this.attrs.delete(n); }
}

// The app page: body > [svg sprite, .stage > [.studio, .device > .edge > [...]], script]
const sheet = new El("DIV", { class: "sheet" });
const menu = new El("DIV", { class: "menu", inert: "" });
const toast = new El("DIV", { class: "toast", role: "status", "aria-live": "polite" });
const appScroll = new El("DIV", { class: "app-scroll" });
const topbar = new El("DIV", { class: "topbar" });
const tabbar = new El("NAV", { class: "tabbar" });
const edge = new El("DIV", { class: "edge" }, [appScroll, topbar, tabbar, menu, sheet, toast]);
const device = new El("DIV", { class: "device" }, [edge]);
const studio = new El("ASIDE", { class: "studio" });
const stage = new El("DIV", { class: "stage" }, [studio, device]);
const sprite = new El("svg");
const script = new El("SCRIPT");
const announcer = new El("DIV", { "aria-live": "assertive" });
const body = new El("BODY", {}, [sprite, stage, script, announcer]);
new El("HTML", {}, [new El("HEAD"), body]);
globalThis.document = { body, createElement: (tag) => new El(tag.toUpperCase()) };

const { announce, ensureAnnouncer, inertOutside } = await tsImport("../app/ui/modal.ts", import.meta.url);

test("everything outside the overlay becomes inert, up to the body", () => {
  const undo = inertOutside(sheet);
  for (const el of [appScroll, topbar, tabbar, studio, sprite]) assert.equal(el.hasAttribute("inert"), true, el.attrs.get("class") ?? el.tagName);
  assert.equal(sheet.hasAttribute("inert"), false, "the overlay itself");
  for (const el of [edge, device, stage]) assert.equal(el.hasAttribute("inert"), false, "its ancestors");
  for (const el of [toast, announcer, script]) assert.equal(el.hasAttribute("inert"), false, "live regions and scripts are left alone");
  undo();
  for (const el of [appScroll, topbar, tabbar, studio, sprite]) assert.equal(el.hasAttribute("inert"), false);
});

test("an element that was already inert stays inert after closing", () => {
  const undo = inertOutside(sheet);
  undo();
  assert.equal(menu.hasAttribute("inert"), true, "the closed menu, whose inert React manages");
});

test("a status nested in the inerted screen is silenced; the page-level announcer is not, and speaks for it", (t) => {
  // A screen's transaction status: a live region inside .app-scroll, not a sibling on the overlay's path.
  const status = new El("DIV", { role: "status" });
  const screenPanel = appScroll.append(new El("SECTION", {}, [status]));
  const region = ensureAnnouncer();
  assert.equal(region.parentElement, body, "a direct child of <body>");
  assert.deepEqual([region.getAttribute("role"), region.getAttribute("aria-live")], ["status", "polite"]);
  assert.equal(ensureAnnouncer(), region, "created once");

  const undo = inertOutside(sheet);
  assert.equal(appScroll.hasAttribute("inert"), true, "the status's screen is inert, so the status itself can't be heard");
  assert.equal(region.hasAttribute("inert"), false, "the announcer stays live");
  t.mock.timers.enable({ apis: ["setTimeout"] });
  announce("Swap: Confirmed.");
  announce("Swap: Confirmed.");
  assert.equal(region.textContent, "", "emptied first, so a repeat is still announced");
  t.mock.timers.tick(100);
  assert.equal(region.textContent, "Swap: Confirmed.");
  undo();
  appScroll.children.splice(appScroll.children.indexOf(screenPanel), 1);
});
