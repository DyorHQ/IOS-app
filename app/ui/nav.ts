import type { ReactNode } from "react";

export type Tab = "home" | "markets" | "launch" | "trade" | "profile";
export type TradeMode = "swap" | "perps";
export type Go = (tab: Tab, mode?: TradeMode) => void;
export type Toast = (message: ReactNode) => void;
