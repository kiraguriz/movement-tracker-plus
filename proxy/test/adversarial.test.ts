import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { INSTALL_LIMIT_PER_HOUR, networkKey } from "../src/auth.ts";
import { POLICIES } from "../src/policy.ts";
import { FAKE_MODEL_KEY, FAKE_USDA_KEY, errorOf, jsonUpstream, makeHarness } from "./helpers.ts";
import type { Harness } from "./helpers.ts";

const OK_BODY = { id: "resp_1", object: "response", status: "completed", output: [] };
const PNG = "data:image/png;base64,iVBORw0KGgo=";

async function setup(): Promise<{ h: Harness; token: string }> {
  const h = makeHarness();
  const token = await h.install();
  h.upstream.handler = () => jsonUpstream(OK_BODY);
  return { h, token };
}

function coach(h: Harness, token: string, feature: string, body: unknown, headers: Record<string, string> = {}) {
  return h.call("/v1/coach/responses", {
    token,
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
    headers: { "content-type": "application/json", "x-coach-feature": feature, ...headers },
  });
}

function budgetValue(h: Harness, scope: string): number {
  const key = h.kv.keys().find((k) => k.includes(`:${scope}:`) && k.startsWith("bud:"));
  return key ? Number(h.kv.store.get(key)?.value) : 0;
}

function tally(responses: Response[]): Record<number, number> {
  const out: Record<number, number> = {};
  for (const r of responses) out[r.status] = (out[r.status] ?? 0) + 1;
  return out;
}

describe("install rate limit", () => {
  it("holds under a parallel burst while KV is slow", async () => {
    const h = makeHarness();
    h.kv.latency = true;
    const burst = await Promise.all(
      Array.from({ length: 40 }, () => h.call("/v1/install", { method: "POST", ip: "198.51.100.9" })),
    );
    assert.deepEqual(tally(burst), { 201: INSTALL_LIMIT_PER_HOUR, 429: 40 - INSTALL_LIMIT_PER_HOUR });
  });

  it("holds when KV rejects same-key writes within a second", async () => {
    const h = makeHarness();
    h.kv.minWriteGapMs = 1000;
    const results: number[] = [];
    for (let i = 0; i < 12; i += 1) {
      results.push((await h.call("/v1/install", { method: "POST", ip: "198.51.100.9" })).status);
    }
    assert.equal(results.filter((s) => s === 201).length, INSTALL_LIMIT_PER_HOUR);
  });

  it("counts a whole IPv6 /64 as one network", async () => {
    const h = makeHarness();
    for (let i = 0; i < 12; i += 1) {
      const res = await h.call("/v1/install", { method: "POST", ip: `2001:db8:1:2:${(i + 1).toString(16)}::9` });
      assert.equal(res.status, i < INSTALL_LIMIT_PER_HOUR ? 201 : 429, `address ${i + 1}`);
    }
    // A different /64 is a different network.
    assert.equal((await h.call("/v1/install", { method: "POST", ip: "2001:db8:1:3::9" })).status, 201);
  });

  it("derives the network key without being fooled by spelling", () => {
    const sameNetwork = [
      "2001:db8:1:2::1",
      "2001:DB8:1:2:ffff:ffff:ffff:ffff",
      "2001:0db8:0001:0002:0:0:0:0",
      "2001:db8:1:2::",
      "2001:db8:1:2:3:4:5:6%eth0",
      " 2001:db8:1:2::7 ",
    ];
    const keys = new Set(sameNetwork.map(networkKey));
    assert.equal(keys.size, 1, [...keys].join(" "));
    assert.notEqual(networkKey("2001:db8:1:3::1"), networkKey("2001:db8:1:2::1"));
    assert.notEqual(networkKey("2001:db8:2:2::1"), networkKey("2001:db8:1:2::1"));
    assert.equal(networkKey("::ffff:203.0.113.5"), "203.0.113.5");
    assert.equal(networkKey("203.0.113.5"), "203.0.113.5");
    assert.equal(networkKey("64:ff9b::192.0.2.1"), networkKey("64:ff9b::1"));
    // Malformed input stays distinct per spelling instead of collapsing everyone into one bucket.
    assert.equal(networkKey("1:2:3::4::5"), "1:2:3::4::5");
    assert.equal(networkKey("zzzz::1"), "zzzz::1");
  });

  it("ignores client-supplied forwarding headers", async () => {
    const h = makeHarness();
    for (let i = 0; i < INSTALL_LIMIT_PER_HOUR; i += 1) {
      await h.call("/v1/install", { method: "POST", ip: "198.51.100.9" });
    }
    const spoofed = await h.call("/v1/install", {
      method: "POST",
      ip: "198.51.100.9",
      headers: { "x-forwarded-for": "10.9.9.9", "x-real-ip": "10.8.8.8", forwarded: "for=10.7.7.7", "true-client-ip": "10.6.6.6" },
    });
    assert.equal(spoofed.status, 429);
  });
});

describe("daily budget under concurrency", () => {
  it("lets exactly the limit through a parallel burst while KV is slow", async () => {
    const { h, token } = await setup();
    h.kv.latency = true;
    const limit = POLICIES.debrief.dailyRequests;
    const burst = await Promise.all(Array.from({ length: limit * 3 }, () => coach(h, token, "debrief", { input: "hi" })));
    assert.deepEqual(tally(burst), { 200: limit, 429: limit * 2 });
    assert.equal(h.calls.length, limit, "only budgeted requests reach upstream");
  });

  it("holds when KV rejects same-key writes within a second", async () => {
    const { h, token } = await setup();
    h.kv.minWriteGapMs = 1000;
    const limit = POLICIES.debrief.dailyRequests;
    const statuses: number[] = [];
    for (let i = 0; i < limit + 10; i += 1) statuses.push((await coach(h, token, "debrief", { input: "hi" })).status);
    assert.equal(statuses.filter((s) => s === 200).length, limit);
    assert.equal(h.calls.length, limit);
  });

  it("keeps counting per token and feature during a burst", async () => {
    const { h, token } = await setup();
    const other = await h.install("203.0.113.2");
    h.kv.latency = true;
    const burst = await Promise.all([
      ...Array.from({ length: 30 }, () => coach(h, token, "debrief", { input: "hi" })),
      ...Array.from({ length: 5 }, () => coach(h, other, "debrief", { input: "hi" })),
      ...Array.from({ length: 5 }, () => coach(h, token, "chat", { input: "hi" })),
    ]);
    assert.deepEqual(tally(burst), { 200: POLICIES.debrief.dailyRequests + 10, 429: 10 });
  });
});

describe("budget refunds", () => {
  it("never turns upstream rejections of invalid requests into free calls", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream({ error: { message: "bad" } }, 400);
    const limit = POLICIES.debrief.dailyRequests;
    for (let i = 0; i < limit; i += 1) {
      assert.equal((await coach(h, token, "debrief", { input: "hi" })).status, 400);
    }
    assert.equal(budgetValue(h, "debrief"), limit);
    const blocked = await coach(h, token, "debrief", { input: "hi" });
    assert.equal((await errorOf(blocked)).code, "daily_budget_exceeded");
    assert.equal(h.calls.length, limit, "once the budget is spent, upstream is not called again");
  });

  it("treats 400, 413 and 422 as the client's fault and everything else as ours", async () => {
    const { h, token } = await setup();
    const cases: [number, boolean][] = [
      [400, false],
      [413, false],
      [422, false],
      [401, true],
      [402, true],
      [403, true],
      [404, true],
      [429, true],
      [500, true],
      [502, true],
      [503, true],
      [504, true],
    ];
    for (const [status, refunded] of cases) {
      const before = budgetValue(h, "chat");
      h.upstream.handler = () => jsonUpstream({ error: { message: "x" } }, status);
      await coach(h, token, "chat", { input: "hi" });
      assert.equal(budgetValue(h, "chat"), before + (refunded ? 0 : 1), `upstream ${status}`);
    }
  });

  it("does not refund voice requests upstream rejected as invalid", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream({ error: { message: "unsupported wav" } }, 400);
    const wav = new Uint8Array(100);
    wav.set(new TextEncoder().encode("RIFF"), 0);
    wav.set(new TextEncoder().encode("WAVE"), 8);
    const fd = new FormData();
    fd.append("audio", new Blob([wav], { type: "audio/wav" }), "a.wav");
    const res = await h.call("/v1/voice/transcribe", { token, method: "POST", body: fd });
    assert.equal(res.status, 400);
    assert.equal(budgetValue(h, "voice"), 1);
  });
});

describe("header hygiene", () => {
  const clientHeaders = {
    cookie: "session=abc",
    "x-forwarded-for": "6.6.6.6",
    "x-api-key": "client-supplied-key",
    "proxy-authorization": "Basic Zm9vOmJhcg==",
    "x-goog-api-key": "k",
    "x-coach-feature-extra": "x",
    origin: "https://evil.example",
    referer: "https://evil.example/",
  };

  it("sends upstream only the server key, content type and accept", async () => {
    const { h, token } = await setup();
    await coach(h, token, "chat", { input: "hi" }, clientHeaders);
    const names = [...(h.calls.at(-1)?.headers.keys() ?? [])].sort();
    assert.deepEqual(names, ["accept", "authorization", "content-type"]);
    assert.equal(h.calls.at(-1)?.headers.get("authorization"), `Bearer ${FAKE_MODEL_KEY}`);
  });

  it("sends USDA only the server key", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream({ foods: [] });
    await h.call("/v1/food/search?q=apple", { token, headers: clientHeaders });
    const names = [...(h.calls.at(-1)?.headers.keys() ?? [])].sort();
    assert.deepEqual(names, ["accept", "x-api-key"]);
    assert.equal(h.calls.at(-1)?.headers.get("x-api-key"), FAKE_USDA_KEY);
  });

  it("never forwards upstream response headers to the app", async () => {
    const leaky = { "set-cookie": "sid=1; Path=/", server: "meta-internal", "x-request-id": "abc", "x-ratelimit-remaining": "3", via: "1.1 edge", "x-powered-by": "x" };
    const forbidden = Object.keys(leaky);
    const { h, token } = await setup();
    const wav = new Uint8Array(100);
    wav.set(new TextEncoder().encode("RIFF"), 0);
    wav.set(new TextEncoder().encode("WAVE"), 8);
    const voiceForm = () => {
      const fd = new FormData();
      fd.append("audio", new Blob([wav], { type: "audio/wav" }), "a.wav");
      return fd;
    };
    const attempts: [string, () => Promise<Response>, number][] = [
      ["coach json", () => coach(h, token, "chat", { input: "hi" }), 200],
      ["coach stream", () => coach(h, token, "chat", { input: "hi", stream: true }), 200],
      ["voice", () => h.call("/v1/voice/transcribe", { token, method: "POST", body: voiceForm() }), 200],
      ["food", () => h.call("/v1/food/search?q=apple", { token }), 200],
      ["coach 429", () => coach(h, token, "chat", { input: "hi" }), 429],
      ["coach 503", () => coach(h, token, "chat", { input: "hi" }), 503],
      ["coach 400", () => coach(h, token, "chat", { input: "hi" }), 400],
    ];
    for (const [name, run, status] of attempts) {
      h.upstream.handler = () =>
        status === 200
          ? name === "coach stream"
            ? new Response("data: [DONE]\n\n", { status, headers: { "content-type": "text/event-stream", ...leaky } })
            : jsonUpstream(name === "food" ? { foods: [] } : OK_BODY, status, leaky)
          : jsonUpstream({ error: { message: "x" } }, status, { ...leaky, "retry-after": "5" });
      const res = await run();
      assert.equal(res.status, status, name);
      await res.arrayBuffer();
      for (const header of forbidden) assert.equal(res.headers.get(header), null, `${name}: ${header}`);
    }
  });

  it("does not follow upstream redirects, so the server key cannot be replayed elsewhere", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => new Response(null, { status: 307, headers: { location: "https://evil.example/steal" } });
    const res = await coach(h, token, "chat", { input: "hi" });
    assert.deepEqual([res.status, (await errorOf(res)).code], [502, "upstream_error"]);
    assert.equal(h.calls.length, 1);
    assert.equal(h.calls[0]?.redirect, "manual");

    const food = await h.call("/v1/food/search?q=apple", { token });
    assert.equal(food.status, 502);
    assert.equal(h.calls.at(-1)?.redirect, "manual");
  });
});

describe("kill switch spellings", () => {
  it("pauses on every common way of saying yes and only those", async () => {
    for (const value of ["1", "true", "TRUE", "True", " 1 ", "on", "ON", "yes", "Yes"]) {
      const h = makeHarness({ env: { KILL_SWITCH: value } });
      const res = await h.call("/v1/install", { method: "POST" });
      assert.equal(res.status, 503, JSON.stringify(value));
      assert.deepEqual(await (await h.call("/v1/health")).json(), { ok: true, killSwitch: true });
    }
    for (const value of ["0", "", "false", "off", "no", "2", "enabled", undefined]) {
      const h = makeHarness({ env: { KILL_SWITCH: value } });
      assert.equal((await h.call("/v1/install", { method: "POST" })).status, 201, JSON.stringify(value));
      assert.deepEqual(await (await h.call("/v1/health")).json(), { ok: true, killSwitch: false });
    }
  });
});

describe("route and token hardening", () => {
  it("answers 404 for path variants of protected routes and never reaches KV or upstream", async () => {
    const h = makeHarness();
    const paths = [
      "/v1/coach/responses/",
      "//v1/coach/responses",
      "/v1/coach/responses%2F",
      "/v1/COACH/responses",
      "/V1/health",
      "/v1/health/",
      "/v1/food/search/",
      "/v1/food/../coach/responses/x",
      "/v1/install/extra",
      "/",
    ];
    for (const path of paths) {
      const res = await h.call(path, { method: "POST", body: "{}", headers: { "x-coach-feature": "chat", authorization: `Bearer ${"A".repeat(43)}` } });
      assert.equal(res.status, 404, path);
      assert.equal((await errorOf(res)).code, "not_found", path);
    }
    assert.equal(h.calls.length, 0);
    assert.equal(h.kv.reads + h.kv.writes, 0);
  });

  it("answers 405 before touching anything for methods a route does not serve", async () => {
    const h = makeHarness();
    const token = "A".repeat(43);
    for (const path of ["/v1/coach/responses", "/v1/voice/transcribe", "/v1/food/search?q=apple", "/v1/install"]) {
      for (const method of ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]) {
        const route = { "/v1/coach/responses": "POST", "/v1/voice/transcribe": "POST", "/v1/food/search?q=apple": "GET", "/v1/install": "POST" }[path];
        if (method === route) continue;
        const res = await h.call(path, { method, token });
        assert.equal(res.status, 405, `${method} ${path}`);
        assert.equal(res.headers.get("allow"), route);
      }
    }
    assert.equal(h.calls.length, 0);
    assert.equal(h.kv.reads + h.kv.writes, 0);
  });

  it("accepts only an Authorization header, never a token in the URL or another header", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream({ foods: [] });
    const viaQuery = await h.call(`/v1/food/search?q=apple&token=${token}&access_token=${token}`);
    assert.equal(viaQuery.status, 401);
    const viaHeader = await h.call("/v1/food/search?q=apple", { headers: { "x-api-key": token, "x-install-token": token, cookie: `token=${token}` } });
    assert.equal(viaHeader.status, 401);
    assert.equal((await errorOf(viaHeader)).code, "missing_token");
    assert.equal(h.calls.length, 0);
  });

  it("rejects ambiguous Authorization headers", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream({ foods: [] });
    const duplicate = new Headers();
    duplicate.append("authorization", `Bearer ${token}`);
    duplicate.append("authorization", `Bearer ${token}`);
    for (const value of [`Bearer ${token} extra`, `Bearer  ${token}`, `Bearer ${token},`, `Token ${token}`, `${token}`]) {
      const res = await h.call("/v1/food/search?q=apple", { headers: { authorization: value } });
      assert.equal(res.status, 401, value);
    }
    const res = await h.call("/v1/food/search?q=apple", { headers: duplicate });
    assert.equal(res.status, 401, "two Authorization headers are folded into one invalid value");
    // The scheme is case-insensitive per RFC 9110, and the plain form still works.
    assert.equal((await h.call("/v1/food/search?q=apple", { headers: { authorization: `bearer ${token}` } })).status, 200);
  });

  it("does not accept what is stored in KV as a token", async () => {
    const { h, token } = await setup();
    const stored = h.kv.keys().find((k) => k.startsWith("tok:"));
    assert.ok(stored);
    const hash = stored.slice("tok:".length);
    assert.notEqual(hash.slice(0, 43), token);
    for (const candidate of [hash.slice(0, 43), `tok:${hash}`.slice(0, 43), hash]) {
      const res = await h.call("/v1/food/search?q=apple", { token: candidate });
      assert.equal(res.status, 401, candidate);
    }
    assert.ok(!h.kv.dump().includes(token));
  });

  it("builds KV keys only from fixed prefixes, hashes and validated scopes", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream(OK_BODY);
    await coach(h, token, "chat", { input: "hi" });
    await h.call("/v1/food/search?q=apple%3Aevil%3A20260101", { token });
    for (const key of h.kv.keys()) {
      assert.match(key, /^(tok:[0-9a-f]{64}|rl:install:[0-9a-f]{24}:\d+|bud:[0-9a-f]{32}:(set_review|debrief|chat|meal_photo|spec_author|voice|food):\d{8})$/, key);
    }
  });
});

describe("errors are always JSON in the documented shape", () => {
  const bodies: [string, BodyInit | null, string][] = [
    ["html", "<html><body>502 Bad Gateway LLM_secret</body></html>", "text/html"],
    ["empty", "", "text/plain"],
    ["binary", new Uint8Array([0, 255, 254, 1]), "application/octet-stream"],
    ["json without error", JSON.stringify({ message: "nope" }), "application/json"],
    ["error is a string", JSON.stringify({ error: "nope LLM_secret" }), "application/json"],
    ["truncated json", '{"error":{"message":"cut off', "application/json"],
  ];
  const statuses = [400, 401, 402, 403, 404, 408, 413, 422, 429, 500, 502, 503, 504, 520];

  it("wraps any upstream failure, whatever its body", async () => {
    const { h, token } = await setup();
    const wav = new Uint8Array(100);
    wav.set(new TextEncoder().encode("RIFF"), 0);
    wav.set(new TextEncoder().encode("WAVE"), 8);
    const routes: [string, () => Promise<Response>][] = [
      ["coach", () => coach(h, token, "chat", { input: "hi" })],
      ["food", () => h.call(`/v1/food/search?q=apple${h.calls.length}`, { token })],
      [
        "voice",
        () => {
          const fd = new FormData();
          fd.append("audio", new Blob([wav], { type: "audio/wav" }), "a.wav");
          return h.call("/v1/voice/transcribe", { token, method: "POST", body: fd });
        },
      ],
    ];
    for (const [route, run] of routes) {
      for (const status of statuses) {
        for (const [label, body, type] of bodies) {
          h.upstream.handler = () => new Response(body, { status, headers: { "content-type": type } });
          const res = await run();
          const where = `${route} ${status} ${label}`;
          assert.ok(res.status >= 400 && res.status < 600, where);
          assert.match(res.headers.get("content-type") ?? "", /^application\/json/, where);
          const text = await res.text();
          const parsed = JSON.parse(text) as { error: { code: unknown; message: unknown } };
          assert.deepEqual(Object.keys(parsed), ["error"], where);
          assert.deepEqual(Object.keys(parsed.error).sort(), ["code", "message"], where);
          assert.equal(typeof parsed.error.code, "string", where);
          assert.equal(typeof parsed.error.message, "string", where);
          assert.ok(!text.includes("LLM_secret") && !text.includes("<html"), where);
        }
      }
    }
  });
});
