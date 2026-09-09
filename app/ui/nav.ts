import type { ReactNode } from "react";

export type Tab = "home" | "markets" | "launch" | "trade" | "profile";
export type TradeMode = "swap" | "perps";
/** Navigation extras: preselected swap tokens, a market or launch to open. */
export type Preset = { in?: string; out?: string; token?: string };
export type Go = (tab: Tab, mode?: TradeMode, preset?: Preset) => void;
export type Toast = (message: ReactNode) => void;
export type SheetName = "receive" | "send" | "activity" | "wallets" | "help";
export type OpenSheet = (sheet: SheetName) => void;
