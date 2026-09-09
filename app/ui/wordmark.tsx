/** Approved raster wordmark, framed without its tagline. Do not retype the logo. */
export function Wordmark({ className = "" }: { className?: string }) {
  return <span className={`brand-wordmark ${className}`}><img src="/brand/dyorhq-wordmark.png" alt="DyorHQ" /></span>;
}
