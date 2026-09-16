import type { Metadata } from "next";
import type { ReactNode } from "react";
import MomentsShell from "./shell";
import "../launchpad/launchpad.css";
import "./moments.css";

export const metadata: Metadata = {
  title: "DyorHQ Moments — collect a moment on Monad",
  description: "Collect a creator's moment as a numbered edition and share in its coin. Early, low-cap, validation-stage assets settled in USDC on Monad.",
};

export default function MomentsLayout({ children }: { children: ReactNode }) {
  return <MomentsShell>{children}</MomentsShell>;
}
