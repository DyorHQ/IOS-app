// One stroke-based icon family, rendered once as an SVG sprite and referenced with <use>.
import type { CSSProperties, ReactNode } from "react";

const ICONS: Record<string, ReactNode> = {
  home: <path d="M4 10.5 12 4l8 6.5V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z" />,
  markets: <path d="M5 19v-6M12 19V5M19 19v-9" />,
  rocket: <><path d="M12 2.5c3.2 2.3 4.7 5.6 4.7 9.6l-1.5 3.4H8.8l-1.5-3.4c0-4 1.5-7.3 4.7-9.6z" /><circle cx="12" cy="10" r="1.6" /><path d="M8.8 15.5 7 19.5l3-1.2M15.2 15.5l1.8 4-3-1.2M10.6 18.5h2.8" /></>,
  trade: <><path d="m3 16 5.5-5.5 4 4L21 6" /><path d="M15 6h6v6" /></>,
  profile: <><circle cx="12" cy="8" r="4" /><path d="M4.5 20.5c.8-3.9 4-6 7.5-6s6.7 2.1 7.5 6" /></>,
  search: <><circle cx="11" cy="11" r="6.5" /><path d="m20 20-4.3-4.3" /></>,
  menu: <path d="M4 7h16M4 12h16M4 17h16" />,
  "chev-down": <path d="m6 9 6 6 6-6" />,
  "chev-right": <path d="m9 6 6 6-6 6" />,
  "chev-left": <path d="m15 6-6 6 6 6" />,
  "arrow-ur": <path d="M7 17 17 7M8 7h9v9" />,
  deposit: <><path d="M12 4v10m-4-4 4 4 4-4" /><path d="M4 16.5V18a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-1.5" /></>,
  withdraw: <><path d="M12 14V4m-4 4 4-4 4 4" /><path d="M4 16.5V18a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-1.5" /></>,
  send: <path d="M21 3 10.5 13.5M21 3l-6.5 18-4-7.5L3 9.5z" />,
  star: <path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1L3.2 9.5l6.1-.9z" />,
  flame: <path d="M12 3c.5 3.5 4.5 5 4.5 9.5a4.5 4.5 0 0 1-9 0c0-1.6.6-2.8 1.5-3.8.3 1.4 1 2.2 2 2.4C11.3 8.6 10.8 5.6 12 3z" />,
  "trend-up": <><path d="m3 17 6-6 4 4 8-8" /><path d="M15 7h6v6" /></>,
  "trend-down": <><path d="m3 7 6 6 4-4 8 8" /><path d="M15 17h6v-6" /></>,
  copy: <><rect x="9" y="9" width="11" height="11" rx="2.5" /><path d="M5 15V6.5A2.5 2.5 0 0 1 7.5 4H16" /></>,
  heart: <path d="M12 20.3S4.5 15.6 4.5 10a4.2 4.2 0 0 1 7.5-2.6A4.2 4.2 0 0 1 19.5 10c0 5.6-7.5 10.3-7.5 10.3z" />,
  comment: <path d="M20 12a8 8 0 0 1-11.7 7.1L4 20l1-4.2A8 8 0 1 1 20 12z" />,
  more: <><circle cx="5" cy="12" r="1.5" fill="currentColor" stroke="none" /><circle cx="12" cy="12" r="1.5" fill="currentColor" stroke="none" /><circle cx="19" cy="12" r="1.5" fill="currentColor" stroke="none" /></>,
  settings: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" /></>,
  sun: <><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></>,
  moon: <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" />,
  check: <path d="m5 12 5 5L20 7" />,
  plus: <path d="M12 5v14M5 12h14" />,
  minus: <path d="M5 12h14" />,
  x: <path d="M6 6l12 12M18 6 6 18" />,
  swap: <path d="M7 4v16M7 20l-3-3M7 20l3-3M17 20V4M17 4l-3 3M17 4l3 3" />,
  trophy: <><path d="M8 21h8M12 17v4M6 4h12v4a6 6 0 0 1-12 0z" /><path d="M6 6H3v2a3 3 0 0 0 3 3M18 6h3v2a3 3 0 0 1-3 3" /></>,
  help: <><circle cx="12" cy="12" r="9" /><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 .9-1 1.7M12 17h.01" /></>,
  logout: <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9" />,
  clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
  sliders: <><path d="M4 7h9M17 7h3M4 12h3M11 12h9M4 17h11M19 17h1" /><circle cx="15" cy="7" r="2" /><circle cx="9" cy="12" r="2" /><circle cx="17" cy="17" r="2" /></>,
  bell: <><path d="M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15z" /><path d="M10 20a2 2 0 0 0 4 0" /></>,
  wallet: <><rect x="3" y="6" width="18" height="13" rx="3" /><path d="M3 10h18M15 14.5h3" /></>,
  layers: <><path d="m12 3 9 5-9 5-9-5z" /><path d="m3 12.5 9 5 9-5M3 17l9 5 9-5" /></>,
  file: <><path d="M7 3h7l5 5v11a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z" /><path d="M14 3v5h5M9 13h6M9 17h6" /></>,
  graduate: <><path d="m2 9 10-4 10 4-10 4z" /><path d="M6 11v4c0 1.5 2.7 3 6 3s6-1.5 6-3v-4M22 9v6" /></>,
  shield: <><path d="M12 3 5 6v5c0 4.5 3 8 7 10 4-2 7-5.5 7-10V6z" /><path d="m9 12 2 2 4-4" /></>,
  eye: <><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12z" /><circle cx="12" cy="12" r="3" /></>,
  signal: <path fill="currentColor" stroke="none" d="M3 16h3v4H3zM8 12.5h3V20H8zM13 8.5h3V20h-3zM18 4h3v16h-3z" />,
  wifi: <><path d="M2.5 9.5a14.5 14.5 0 0 1 19 0M5.5 12.8a10 10 0 0 1 13 0M8.6 16a5.3 5.3 0 0 1 6.8 0" /><circle cx="12" cy="19.2" r="1.1" fill="currentColor" stroke="none" /></>,
};
export type IconName = keyof typeof ICONS;

export function Sprite() {
  return (
    <svg className="sprite" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      {Object.entries(ICONS).map(([id, body]) => <symbol key={id} id={`i-${id}`} viewBox="0 0 24 24">{body}</symbol>)}
    </svg>
  );
}
export function Icon({ name, className = "", style }: { name: IconName; className?: string; style?: CSSProperties }) {
  return <svg className={`ic${className ? " " + className : ""}`} aria-hidden="true" style={style}><use href={`#i-${name}`} /></svg>;
}
