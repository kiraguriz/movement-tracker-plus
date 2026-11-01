import { HttpError } from "./http.ts";
import { ledgerCall } from "./ledger.ts";
import type { Ctx } from "./types.ts";

const DAY_MS = 86_400_000;
const HOUR_MS = 3_600_000;
// Upper bound on counters remembered per isolate; expired ones are swept first.
const MAX_LOCAL_COUNTS = 20_000;

export function parseCount(raw: string | null): number {
  if (raw === null) return 0;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

export function utcDay(nowMs: number): string {
  return new Date(nowMs).toISOString().slice(0, 10).replaceAll("-", "");
}

export function secondsToUtcMidnight(nowMs: number): number {
  const next = (Math.floor(nowMs / DAY_MS) + 1) * DAY_MS;
  return Math.max(1, Math.ceil((next - nowMs) / 1000));
}

export function secondsToNextHour(nowMs: number): number {
  const next = (Math.floor(nowMs / HOUR_MS) + 1) * HOUR_MS;
  return Math.max(1, Math.ceil((next - nowMs) / 1000));
}

// KV has no atomic increment, is eventually consistent, and rejects a second write to the same key
// within a second. A burst of parallel requests would therefore all read the same stored count and all
// pass. Each isolate also keeps its own count per key and uses the larger of the two. That count is read
// and written with no await in between, so requests handled by one isolate are counted exactly even when
// KV lags or rejects the write. Requests spread over several isolates or locations remain best effort
// (README, "Known limits").
function localCount(ctx: Ctx, key: string, now: number): number {
  const entry = ctx.state.counts.get(key);
  if (!entry) return 0;
  if (entry.expiresAt <= now) {
    ctx.state.counts.delete(key);
    return 0;
  }
  return entry.n;
}

function setLocalCount(ctx: Ctx, key: string, n: number, expiresAt: number): void {
  const counts = ctx.state.counts;
  if (counts.size >= MAX_LOCAL_COUNTS && !counts.has(key)) {
    const now = ctx.deps.now();
    for (const [k, v] of counts) if (v.expiresAt <= now) counts.delete(k);
    if (counts.size >= MAX_LOCAL_COUNTS) counts.clear();
  }
  counts.set(key, { n, expiresAt });
}

async function storeCount(ctx: Ctx, key: string, n: number, ttlSeconds: number): Promise<void> {
  try {
    await ctx.env.PROXY_KV.put(key, String(n), { expirationTtl: Math.max(60, ttlSeconds) });
  } catch {
    // A rejected write only loosens the limit for other isolates; this isolate keeps its own count.
  }
}

// Adds one to the counter and returns the new value.
export async function bumpCounter(ctx: Ctx, key: string, ttlSeconds: number): Promise<number> {
  const durable = await ledgerCall(ctx, { op: "install", key, ttl: ttlSeconds });
  if (durable) return Number(durable.count);
  const stored = parseCount(await ctx.env.PROXY_KV.get(key));
  const now = ctx.deps.now();
  const next = Math.max(stored, localCount(ctx, key, now)) + 1;
  setLocalCount(ctx, key, next, now + ttlSeconds * 1000);
  await storeCount(ctx, key, next, ttlSeconds);
  return next;
}

export interface Reservation {
  key: string;
  ttlSeconds: number;
  ledgerID?: string;
}

// Counts one request against the token's daily budget for `scope` (a coach feature, "voice" or "food").
// The reservation is taken before the upstream call so parallel requests cannot all pass the check.
export async function reserveBudget(ctx: Ctx, scope: string, limit: number): Promise<Reservation> {
  const key = `bud:${ctx.tokenId}:${scope}:${utcDay(ctx.deps.now())}`;
  const ttlSeconds = secondsToUtcMidnight(ctx.deps.now()) + 3600;
  const id = Array.from(ctx.deps.randomBytes(16), (byte) => byte.toString(16).padStart(2, "0")).join("");
  const durable = await ledgerCall(ctx, { op: "reserve", key, ttl: ttlSeconds, limit, id });
  if (durable) return { key, ttlSeconds, ledgerID: id };
  const stored = parseCount(await ctx.env.PROXY_KV.get(key));
  const now = ctx.deps.now();
  const untilMidnight = secondsToUtcMidnight(now);
  const used = Math.max(stored, localCount(ctx, key, now));
  if (used >= limit) {
    throw new HttpError(
      429,
      "daily_budget_exceeded",
      `The daily limit of ${limit} ${scope} requests was reached; it resets at 00:00 UTC`,
      { "retry-after": String(untilMidnight) },
    );
  }
  setLocalCount(ctx, key, used + 1, now + ttlSeconds * 1000);
  await storeCount(ctx, key, used + 1, ttlSeconds);
  return { key, ttlSeconds };
}

// Gives the request back when the failure was not the client's doing, so the user is not charged for
// our outage. Callers must not refund requests upstream rejected as invalid: a refunded rejection is a
// free upstream call, and a loop of them would eat the shared team rate limit.
export async function refundBudget(ctx: Ctx, reservation: Reservation): Promise<void> {
  if (reservation.ledgerID) {
    try { await ledgerCall(ctx, { op: "refund", id: reservation.ledgerID }); } catch { /* Conservative: keep the debit. */ }
    return;
  }
  try {
    const stored = parseCount(await ctx.env.PROXY_KV.get(reservation.key));
    const now = ctx.deps.now();
    const current = Math.max(stored, localCount(ctx, reservation.key, now));
    if (current > 0) {
      setLocalCount(ctx, reservation.key, current - 1, now + reservation.ttlSeconds * 1000);
      await storeCount(ctx, reservation.key, current - 1, reservation.ttlSeconds);
    }
  } catch {
    // Best effort.
  }
}
