// The pg_cron tick's only credential: the x-history-cron header, equal to the HISTORY_CRON_SECRET Edge secret (and the
// Vault secret history_cron_secret the job reads). The function runs with verify_jwt = false, so this check is the gate.
// Both values are hashed (SHA-256) and the 32-byte digests compared with a fixed-length loop, so neither the secret's
// length nor a matching prefix shows in the timing.
export const MIN_SECRET_LENGTH = 32;

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

export async function cronAuthorized(presented: string | null, secret: string | undefined): Promise<boolean> {
  if (!secret || secret.length < MIN_SECRET_LENGTH || presented === null) return false;
  const [a, b] = await Promise.all([digest(presented), digest(secret)]);
  let diff = 0;
  for (let i = 0; i < 32; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
