import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { describe, it } from "node:test";
import { createApp } from "../src/app.ts";
import { BudgetLedger, type LedgerStorage } from "../src/ledger.ts";
import type { Deps } from "../src/types.ts";
import { makeHarness } from "./helpers.ts";

class SQLiteStorage implements LedgerStorage {
  database = new DatabaseSync(":memory:");
  sql = {
    exec: <T extends Record<string, unknown>>(query: string, ...bindings: (string | number)[]) => {
      const rows = this.database.prepare(query).all(...bindings) as T[];
      return { toArray: () => rows };
    },
  };
  transactionSync<T>(body: () => T): T {
    this.database.exec("BEGIN");
    try { const result = body(); this.database.exec("COMMIT"); return result; }
    catch (error) { this.database.exec("ROLLBACK"); throw error; }
  }
}

function ledgerHarness(env: Record<string, string> = {}) {
  const h = makeHarness({ env });
  const storage = new SQLiteStorage();
  const ledger = new BudgetLedger({ storage }, h.env, h.clock.now);
  h.env.BUDGET_LEDGER = { idFromName: () => "global", get: () => ledger };
  h.env.REQUIRE_DURABLE_BUDGETS = "1";
  const call = (body: unknown) => ledger.fetch(new Request("https://internal/", { method: "POST", body: JSON.stringify(body) }));
  const reserve = (key = "token:chat", limit = 100) => call({ op: "reserve", key, limit, ttl: 86400, id: crypto.randomUUID().replaceAll("-", "") });
  return { h, ledger, storage, call, reserve };
}

describe("durable budgets", () => {
  it("enforces a token budget under a concurrent burst and preserves the count across object recreation", async () => {
    const { h, storage, reserve } = ledgerHarness();
    const responses = await Promise.all(Array.from({ length: 40 }, () => reserve("token:meal_photo", 7)));
    assert.equal(responses.filter((r) => r.status === 200).length, 7);
    assert.equal(responses.filter((r) => r.status === 429).length, 33);
    const recreated = new BudgetLedger({ storage }, h.env, h.clock.now);
    const response = await recreated.fetch(new Request("https://internal/", { method: "POST", body: JSON.stringify({
      op: "reserve", key: "token:meal_photo", limit: 7, ttl: 86400, id: "1".repeat(32),
    }) }));
    assert.equal(response.status, 429);
  });

  it("atomically shares a global cap between different tokens", async () => {
    const { reserve } = ledgerHarness({ GLOBAL_DAILY_REQUESTS: "3" });
    const responses = await Promise.all(Array.from({ length: 20 }, (_, i) => reserve(`token${i}:chat`)));
    assert.equal(responses.filter((r) => r.status === 200).length, 3);
    assert.equal(responses.filter((r) => r.status === 429).length, 17);
  });

  it("refunds once, keeps the hard attempt cap, and resets at UTC midnight", async () => {
    const { h, call, reserve } = ledgerHarness({ GLOBAL_DAILY_REQUESTS: "1", GLOBAL_DAILY_ATTEMPTS: "2" });
    const first = await reserve();
    const receipt = await first.json() as { id: string };
    await call({ op: "refund", id: receipt.id });
    await call({ op: "refund", id: receipt.id });
    const second = await reserve();
    assert.equal(second.status, 200);
    const secondID = (await second.json() as { id: string }).id;
    await call({ op: "refund", id: secondID });
    assert.equal((await reserve()).status, 429);
    h.clock.advance(86400_000);
    assert.equal((await reserve()).status, 200);
  });

  it("limits installs per network/hour and globally without committing a rejected reservation", async () => {
    const { h } = ledgerHarness({ GLOBAL_DAILY_INSTALLS: "6" });
    const burst = await Promise.all(Array.from({ length: 12 }, () => h.call("/v1/install", { method: "POST", ip: "198.51.100.3" })));
    assert.equal(burst.filter((r) => r.status === 201).length, 5);
    assert.equal((await h.call("/v1/install", { method: "POST", ip: "198.51.100.4" })).status, 201);
    assert.equal((await h.call("/v1/install", { method: "POST", ip: "198.51.100.5" })).status, 429);
  });

  it("limits separate Worker instances through the same object before making paid calls", async () => {
    const { h } = ledgerHarness({ GLOBAL_DAILY_REQUESTS: "4" });
    const token = await h.install();
    let upstreamCalls = 0;
    const deps: Deps = {
      fetch: async () => { upstreamCalls += 1; return new Response("{}", { headers: { "content-type": "application/json" } }); },
      now: h.clock.now, randomBytes: (length) => crypto.getRandomValues(new Uint8Array(length)),
      getCache: () => null, log: () => {},
    };
    const apps = Array.from({ length: 20 }, () => createApp(deps));
    const responses = await Promise.all(apps.map((app) => app.fetch(new Request("https://proxy/v1/coach/responses", {
      method: "POST", headers: { authorization: `Bearer ${token}`, "x-coach-feature": "chat", "content-type": "application/json" },
      body: JSON.stringify({ input: "hello" }),
    }), h.env, { waitUntil: () => {} })));
    assert.equal(responses.filter((r) => r.status === 200).length, 4);
    assert.equal(upstreamCalls, 4);
  });

  it("fails closed when the required binding is absent or inaccessible", async () => {
    const h = makeHarness({ env: { REQUIRE_DURABLE_BUDGETS: "1" } });
    assert.equal((await h.call("/v1/install", { method: "POST" })).status, 503);
    h.env.BUDGET_LEDGER = { idFromName: () => "global", get: () => ({ fetch: async () => { throw new Error("offline"); } }) };
    assert.equal((await h.call("/v1/install", { method: "POST" })).status, 503);
    assert.equal(h.calls.length, 0);
  });
});
