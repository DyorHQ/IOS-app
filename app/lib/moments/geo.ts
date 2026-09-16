"use client";

import { useAsync } from "../use-async";

/* Geofence state for the Moments money actions. The Worker answers /api/moments/geo from Cloudflare's country
   detection and a MOMENTS_BLOCKED_COUNTRIES variable; outside the Worker (local dev) the endpoint does not exist
   and the state is "unknown", which does not block. A blocked country disables collect and publish in the UI;
   the contracts themselves are permissionless, so this is a product/legal control, not a security boundary. */

export type Geo = { country: string | null; blocked: boolean; known: boolean };

export async function fetchGeo(): Promise<Geo> {
  try {
    const res = await fetch("/api/moments/geo", { cache: "no-store" });
    if (!res.ok) return { country: null, blocked: false, known: false };
    const data = (await res.json()) as { country: string | null; blocked: boolean };
    return { country: data.country ?? null, blocked: !!data.blocked, known: true };
  } catch {
    return { country: null, blocked: false, known: false };
  }
}

export function useGeo(): Geo {
  const geo = useAsync(fetchGeo, "moments-geo", 10 * 60_000);
  return geo.data ?? { country: null, blocked: false, known: false };
}
