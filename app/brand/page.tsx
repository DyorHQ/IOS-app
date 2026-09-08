import type { Metadata } from "next";
import BrandSystem from "./system";
import "./brand.css";

export const metadata: Metadata = { title: "DyorHQ | Design system" };
export default function Brand() { return <BrandSystem />; }
