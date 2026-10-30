import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { TOKEN_CACHE_TTL_MS } from "../src/auth.ts";
import { FAKE_MODEL_KEY, FAKE_USDA_KEY, errorOf, jsonUpstream, makeHarness, post } from "./helpers.ts";

const HOUR = 3_600_000;

describe("health", () => {
  it("answers without auth and reports the kill switch", async () => {
    const h = makeHarness();
    const res = await h.call("/v1/health");
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true, killSwitch: false });
  });
});

describe("install", () => {
  it("issues a 256-bit base64url token and stores only its hash", async () => {
    const h = makeHarness();
    const res = await h.call("/v1/install", { method: "POST", ip: "198.51.100.7" });
    assert.equal(res.status, 201);
    const body = (await res.json()) as { token: string; expiresAt: string };
    assert.match(body.token, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(Buffer.from(body.token, "base64url").length, 32);
    assert.ok(Date.parse(body.expiresAt) > h.clock.t);
    // Neither the token nor the caller's IP is stored in the clear.
    assert.ok(!h.kv.dump().includes(body.token));
    assert.ok(!h.kv.dump().includes("198.51.100.7"));
    assert.equal(h.kv.keys().filter((k) => k.startsWith("tok:")).length, 1);
  });

  it("issues distinct tokens", async () => {
    const h = makeHarness();
    const a = await h.install();
    const b = await h.install();
    assert.notEqual(a, b);
  });

  it("allows 5 installs per hour per IP, then 429 with Retry-After", async () => {
    const h = makeHarness();
    for (let i = 0; i < 5; i += 1) {
      const res = await h.call("/v1/install", { method: "POST", ip: "198.51.100.9" });
      assert.equal(res.status, 201);
    }
    h.clock.advance(10 * 60 * 1000); // 12:10 UTC, 50 minutes left in the hour
    const blocked = await h.call("/v1/install", { method: "POST", ip: "198.51.100.9" });
    assert.equal(blocked.status, 429);
    assert.equal(blocked.headers.get("retry-after"), String(50 * 60));
    assert.equal((await errorOf(blocked)).code, "install_rate_limited");
  });

  it("limits per IP, not globally, and resets in the next hour", async () => {
    const h = makeHarness();
    for (let i = 0; i < 5; i += 1) await h.call("/v1/install", { method: "POST", ip: "198.51.100.9" });
    const other = await h.call("/v1/install", { method: "POST", ip: "198.51.100.10" });
    assert.equal(other.status, 201);
    h.clock.advance(HOUR);
    const later = await h.call("/v1/install", { method: "POST", ip: "198.51.100.9" });
    assert.equal(later.status, 201);
  });

  it("rejects other methods", async () => {
    const h = makeHarness();
    const res = await h.call("/v1/install");
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("allow"), "POST");
  });
});

describe("auth", () => {
  const protectedRoutes: [string, RequestInit][] = [
    ["/v1/coach/responses", { method: "POST", body: "{}" }],
    ["/v1/voice/transcribe", { method: "POST", body: "x" }],
    ["/v1/food/search?q=apple", { method: "GET" }],
  ];

  it("returns 401 missing_token on every protected route", async () => {
    const h = makeHarness();
    for (const [path, init] of protectedRoutes) {
      const res = await h.call(path, init);
      assert.equal(res.status, 401, path);
      assert.equal((await errorOf(res)).code, "missing_token", path);
      assert.equal(res.headers.get("www-authenticate"), "Bearer");
    }
    assert.equal(h.calls.length, 0);
  });

  it("rejects malformed tokens without touching KV", async () => {
    const h = makeHarness();
    for (const bad of ["short", "x".repeat(44), `${"a".repeat(42)}!`]) {
      const res = await h.call("/v1/food/search?q=apple", { token: bad });
      assert.equal(res.status, 401);
      assert.equal((await errorOf(res)).code, "invalid_token");
    }
    const basic = await h.call("/v1/food/search?q=apple", { headers: { authorization: "Basic abc" } });
    assert.equal(basic.status, 401);
    assert.equal(h.kv.reads, 0);
  });

  it("rejects well-formed tokens that were never issued", async () => {
    const h = makeHarness();
    const res = await h.call("/v1/food/search?q=apple", { token: "A".repeat(43) });
    assert.equal(res.status, 401);
    assert.equal((await errorOf(res)).code, "invalid_token");
    assert.equal(h.calls.length, 0);
  });

  it("caches positive lookups per isolate and re-checks KV after the TTL", async () => {
    const h = makeHarness();
    const token = await h.install();
    h.upstream.handler = () => jsonUpstream({ foods: [] });
    const lookups = () => h.kv.readKeys.filter((k) => k.startsWith("tok:")).length;

    assert.equal((await h.call("/v1/food/search?q=apple", { token })).status, 200);
    assert.equal(lookups(), 1);
    assert.equal((await h.call("/v1/food/search?q=pear", { token })).status, 200);
    assert.equal(lookups(), 1, "second request is served from the isolate cache");

    // Revoke: still accepted inside the cache window, rejected after it.
    for (const key of h.kv.keys()) if (key.startsWith("tok:")) await h.kv.delete(key);
    assert.equal((await h.call("/v1/food/search?q=plum", { token })).status, 200);
    h.clock.advance(TOKEN_CACHE_TTL_MS + 1000);
    const revoked = await h.call("/v1/food/search?q=fig", { token });
    assert.equal(revoked.status, 401);
    assert.equal(lookups(), 2);
  });

  it("does not forward the install token upstream", async () => {
    const h = makeHarness();
    const token = await h.install();
    h.upstream.handler = () => jsonUpstream({ foods: [] });
    await h.call("/v1/food/search?q=apple", { token });
    assert.equal(h.calls.length, 1);
    assert.ok(!(h.calls[0]?.headers.get("authorization") ?? "").includes(token));
    assert.ok(!(h.calls[0]?.url ?? "").includes(token));
  });
});

describe("routing", () => {
  it("returns a JSON 404 for unknown routes", async () => {
    const h = makeHarness();
    const res = await h.call("/v1/nope");
    assert.deepEqual(await errorOf(res), { status: 404, code: "not_found", message: "Unknown route" });
    assert.match(res.headers.get("content-type") ?? "", /application\/json/);
  });

  it("returns 405 with Allow for a wrong method", async () => {
    const h = makeHarness();
    const res = await h.call("/v1/food/search?q=apple", { method: "POST" });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("allow"), "GET");
  });
});

describe("kill switch", () => {
  it("returns 503 everywhere except GET /v1/health", async () => {
    const h = makeHarness({ env: { KILL_SWITCH: "1" } });
    const token = "A".repeat(43);
    const attempts: [string, RequestInit][] = [
      ["/v1/install", { method: "POST" }],
      ["/v1/coach/responses", { method: "POST", body: "{}" }],
      ["/v1/voice/transcribe", { method: "POST", body: "x" }],
      ["/v1/food/search?q=apple", { method: "GET" }],
      ["/v1/unknown", { method: "GET" }],
      ["/v1/health", { method: "POST" }],
    ];
    for (const [path, init] of attempts) {
      const res = await h.call(path, { ...init, token });
      assert.equal(res.status, 503, path);
      assert.equal((await errorOf(res)).code, "service_paused");
      assert.equal(res.headers.get("retry-after"), "300");
    }
    const health = await h.call("/v1/health");
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { ok: true, killSwitch: true });
    assert.equal(h.calls.length, 0);
    assert.equal(h.kv.reads + h.kv.writes, 0);
  });

  it("only the exact value 1 pauses the service", async () => {
    const h = makeHarness({ env: { KILL_SWITCH: "0" } });
    assert.equal((await h.call("/v1/install", { method: "POST" })).status, 201);
  });
});

describe("logging and errors", () => {
  it("logs only route, status, latency and feature", async () => {
    const h = makeHarness();
    const token = await h.install();
    h.upstream.handler = () => jsonUpstream({ id: "resp_1", output: [] });
    await h.call(...post("/v1/coach/responses", { input: "secret workout note 12345" }, {
      authorization: `Bearer ${token}`,
      "x-coach-feature": "chat",
    }));
    await h.call("/v1/food/search?q=very+private+meal", { token });
    assert.ok(h.logs.length >= 3);
    for (const entry of h.logs) {
      assert.deepEqual(Object.keys(entry).sort().filter((k) => k !== "feature"), ["ms", "route", "status"]);
      const text = JSON.stringify(entry);
      for (const forbidden of [token, FAKE_MODEL_KEY, FAKE_USDA_KEY, "secret workout", "private meal"]) {
        assert.ok(!text.includes(forbidden));
      }
    }
    const coach = h.logs.find((l) => l.route === "coach");
    assert.equal(coach?.feature, "chat");
    assert.equal(coach?.status, 200);
    assert.deepEqual(h.logs.map((l) => l.route), ["install", "coach", "food"]);
  });

  it("does not leak transport error details from upstream failures", async () => {
    const h = makeHarness();
    const token = await h.install();
    h.upstream.handler = () => {
      throw new Error("boom with LLM_SECRET");
    };
    const err = await errorOf(await h.call("/v1/food/search?q=apple", { token }));
    assert.equal(err.status, 502);
    assert.equal(err.code, "upstream_unreachable");
    assert.ok(!err.message.includes("LLM_SECRET"));
  });

  it("turns unexpected internal exceptions into a generic 500", async () => {
    const h = makeHarness();
    h.kv.get = async () => {
      throw new Error("kv down LLM_SECRET");
    };
    const res = await h.call("/v1/food/search?q=apple", { token: "A".repeat(43) });
    assert.deepEqual(await errorOf(res), { status: 500, code: "internal", message: "Internal error" });
    assert.equal(h.logs.at(-1)?.status, 500);
  });
});
