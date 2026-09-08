/** Approved raster wordmark, framed without its tagline. Do not retype the logo. */
export function Wordmark({ className = "" }: { className?: string }) {
  return <span className={`brand-wordmark ${className}`}><img src="/brand/dyorhq-serif-v2-transparent.png" alt="DyorHQ" width="1774" height="887" /></span>;
}
