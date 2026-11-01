import { HttpError, isObject, jsonResponse } from "./http.ts";
import type { Ctx, Env } from "./types.ts";

export interface LedgerStorage {
  sql: { exec<T extends Record<string, unknown>>(query: string, ...bindings: (string | number)[]): { toArray(): T[] } };
  transactionSync<T>(body: () => T): T;
}

function cap(raw: string | undefined, fallback: number): number {
  if (!raw || !/^\d+$/.test(raw)) return fallback;
  return Math.max(1, Math.min(100_000, Number(raw)));
}

function limited(code: string): HttpError {
  return new HttpError(429, code, "The service usage limit was reached; try again after the UTC day resets", {
    "retry-after": String(Math.max(1, Math.ceil((86_400_000 - Date.now() % 86_400_000) / 1000))),
  });
}

/// One named object serializes all budget reservations across Worker isolates and edge locations.
/// It stores only counters and random reservation ids, never request bodies, keys or raw tokens/IPs.
/// The SQLite-backed storage transaction either commits all counters or none of them.
export class BudgetLedger {
  private readonly storage: LedgerStorage;
  private readonly env: Env;
  private readonly now: () => number;

  constructor(state: { storage: LedgerStorage }, env: Env, now: () => number = Date.now) {
    this.storage = state.storage;
    this.env = env;
    this.now = now;
    this.storage.sql.exec("CREATE TABLE IF NOT EXISTS counters (key TEXT PRIMARY KEY, used INTEGER NOT NULL, expires REAL NOT NULL)");
    this.storage.sql.exec("CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, key TEXT NOT NULL, day TEXT NOT NULL)");
  }

  async fetch(request: Request): Promise<Response> {
    try {
      if (request.method !== "POST") return jsonResponse(405, { error: "method_not_allowed" });
      const body: unknown = await request.json();
      if (!isObject(body) || typeof body.op !== "string") throw new HttpError(400, "invalid_ledger_request", "Invalid operation");
      const now = this.now();
      const day = new Date(now).toISOString().slice(0, 10);
      const expiry = (Math.floor(now / 86400_000) + 1) * 86400_000;
      const global = `global:requests:${day}`;
      const attempts = `global:attempts:${day}`;
      const installs = `global:installs:${day}`;
      const sql = this.storage.sql;
      const count = (key: string): number => sql.exec<{ used: number }>("SELECT used FROM counters WHERE key = ?", key).toArray()[0]?.used ?? 0;
      const set = (key: string, used: number, expires: number): void => {
        sql.exec("INSERT INTO counters (key, used, expires) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET used=excluded.used, expires=excluded.expires", key, used, expires);
      };
      const result = this.storage.transactionSync(() => {
        sql.exec("DELETE FROM counters WHERE expires <= ?", now);
        sql.exec("DELETE FROM receipts WHERE day <> ?", day);
        if (body.op === "refund") {
          if (typeof body.id !== "string") throw new HttpError(400, "invalid_ledger_request", "Invalid reservation");
          const receipt = sql.exec<{ key: string }>("SELECT key FROM receipts WHERE id = ?", body.id).toArray()[0];
          if (receipt) {
            sql.exec("DELETE FROM receipts WHERE id = ?", body.id);
            sql.exec("UPDATE counters SET used = MAX(0, used - 1) WHERE key = ? OR key = ?", receipt.key, global);
          }
          return { ok: true };
        }
        if (typeof body.key !== "string" || body.key.length > 200 || !/^[\w:.-]+$/.test(body.key)
            || typeof body.ttl !== "number" || !Number.isInteger(body.ttl) || body.ttl < 1 || body.ttl > 172800) {
          throw new HttpError(400, "invalid_ledger_request", "Invalid counter");
        }
        const current = count(body.key);
        if (body.op === "install") {
          const used = count(installs);
          if (used >= cap(this.env.GLOBAL_DAILY_INSTALLS, 200)) throw limited("global_install_limit");
          if (current >= 5) throw new HttpError(429, "install_rate_limited", "Too many installs from this network", { "retry-after": "3600" });
          set(installs, used + 1, expiry);
        } else if (body.op === "reserve") {
          if (typeof body.limit !== "number" || !Number.isInteger(body.limit) || body.limit < 1 || body.limit > 1000
              || typeof body.id !== "string" || !/^[a-f0-9]{32}$/.test(body.id)) {
            throw new HttpError(400, "invalid_ledger_request", "Invalid reservation");
          }
          if (sql.exec("SELECT id FROM receipts WHERE id = ?", body.id).toArray().length) return { id: body.id };
          if (current >= body.limit) throw limited("daily_budget_exceeded");
          const used = count(global);
          if (used >= cap(this.env.GLOBAL_DAILY_REQUESTS, 500)) throw limited("global_budget_exceeded");
          const attempted = count(attempts);
          // Refunding an upstream outage never refunds this hard attempt cap.
          if (attempted >= cap(this.env.GLOBAL_DAILY_ATTEMPTS, 2000)) throw limited("global_attempt_limit");
          set(global, used + 1, expiry);
          set(attempts, attempted + 1, expiry);
          sql.exec("INSERT INTO receipts (id, key, day) VALUES (?, ?, ?)", body.id, body.key, day);
        } else {
          throw new HttpError(400, "invalid_ledger_request", "Unknown operation");
        }
        set(body.key, current + 1, now + body.ttl * 1000);
        return { count: current + 1, id: body.id };
      });
      return jsonResponse(200, result);
    } catch (error) {
      if (error instanceof HttpError) return error.toResponse();
      return jsonResponse(503, { error: { code: "budget_unavailable", message: "Usage ledger unavailable" } });
    }
  }
}

/// Missing or unavailable production bindings fail closed, before any paid upstream call.
export async function ledgerCall(ctx: Ctx, body: Record<string, unknown>): Promise<Record<string, unknown> | null> {
  const namespace = ctx.env.BUDGET_LEDGER;
  if (!namespace) {
    if (ctx.env.REQUIRE_DURABLE_BUDGETS === "1") throw new HttpError(503, "budget_unavailable", "Usage ledger is not configured");
    return null; // Legacy/local tests can explicitly omit the binding. Deployment requires it.
  }
  try {
    const response = await namespace.get(namespace.idFromName("global-v1")).fetch(new Request("https://ledger.internal/", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
    }));
    const result: unknown = await response.json();
    if (!response.ok) {
      const detail = isObject(result) && isObject(result.error) ? result.error : {};
      throw new HttpError(response.status === 429 ? 429 : 503,
        typeof detail.code === "string" ? detail.code : "budget_unavailable",
        typeof detail.message === "string" ? detail.message : "Usage ledger unavailable",
        response.headers.has("retry-after") ? { "retry-after": response.headers.get("retry-after")! } : {});
    }
    if (!isObject(result)) throw new Error("invalid ledger response");
    return result;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(503, "budget_unavailable", "Usage ledger unavailable");
  }
}
