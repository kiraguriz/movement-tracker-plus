import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { HttpError } from "../src/http.ts";
import { FEATURES, MIN_OUTPUT_TOKENS, POLICIES } from "../src/policy.ts";
import type { Feature } from "../src/policy.ts";
import { fetchUpstream } from "../src/upstream.ts";
import type { Ctx } from "../src/types.ts";
import { FAKE_MODEL_KEY, MUSE_BASE, errorOf, jsonUpstream, makeHarness } from "./helpers.ts";
import type { Harness } from "./helpers.ts";

const OK_BODY = { id: "resp_1", object: "response", status: "completed", output: [], usage: { output_tokens: 10 } };
const PNG = "data:image/png;base64,iVBORw0KGgo=";

async function setup(): Promise<{ h: Harness; token: string }> {
  const h = makeHarness();
  const token = await h.install();
  h.upstream.handler = () => jsonUpstream(OK_BODY);
  return { h, token };
}

function coach(
  h: Harness,
  token: string,
  feature: string | null,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<Response> {
  const hdrs: Record<string, string> = { "content-type": "application/json", ...headers };
  if (feature !== null) hdrs["x-coach-feature"] = feature;
  return h.call("/v1/coach/responses", {
    token,
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
    headers: hdrs,
  });
}

function sentUpstream(h: Harness): Record<string, unknown> {
  const call = h.calls.at(-1);
  assert.ok(call, "expected an upstream call");
  return JSON.parse(call.bodyText) as Record<string, unknown>;
}

function budgetCount(h: Harness): number {
  const key = h.kv.keys().find((k) => k.startsWith("bud:"));
  return key ? Number(h.kv.store.get(key)?.value) : 0;
}

describe("coach request forwarding", () => {
  it("requires a known X-Coach-Feature header", async () => {
    const { h, token } = await setup();
    for (const feature of [null, "", "unknown", "SET_REVIEW"]) {
      const err = await errorOf(await coach(h, token, feature, { input: "hi" }));
      assert.deepEqual([err.status, err.code], [400, "invalid_feature"]);
    }
    assert.equal(h.calls.length, 0);
  });

  it("forwards to {MUSE_BASE_URL}/responses with the server key only", async () => {
    const { h, token } = await setup();
    const res = await coach(h, token, "chat", { input: "hi" });
    assert.equal(res.status, 200);
    const call = h.calls.at(-1);
    assert.equal(call?.url, `${MUSE_BASE}/responses`);
    assert.equal(call?.method, "POST");
    assert.equal(call?.headers.get("authorization"), `Bearer ${FAKE_MODEL_KEY}`);
    assert.equal(call?.headers.get("content-type"), "application/json");
    assert.equal(call?.headers.get("accept"), "application/json");
    assert.ok(!call?.bodyText.includes(token));
  });

  it("tolerates a trailing slash in MUSE_BASE_URL", async () => {
    const h = makeHarness({ env: { MUSE_BASE_URL: `${MUSE_BASE}//` } });
    const token = await h.install();
    h.upstream.handler = () => jsonUpstream(OK_BODY);
    await coach(h, token, "chat", { input: "hi" });
    assert.equal(h.calls.at(-1)?.url, `${MUSE_BASE}/responses`);
  });

  it("applies each feature's default model, effort and token budget", async () => {
    const { h, token } = await setup();
    for (const feature of FEATURES) {
      const policy = POLICIES[feature];
      const res = await coach(h, token, feature, { input: "hi" });
      assert.equal(res.status, 200, feature);
      const sent = sentUpstream(h);
      assert.equal(sent.model, "muse-spark-1.3");
      assert.deepEqual(sent.reasoning, { effort: policy.defaultEffort }, feature);
      assert.equal(sent.max_output_tokens, policy.defaultMaxOutputTokens, feature);
      assert.equal(sent.store, false);
      assert.equal(sent.stream, undefined);
    }
  });

  it("rebuilds the upstream body from an explicit allowlist", async () => {
    const { h, token } = await setup();
    const request = {
      model: "muse-spark-1.2",
      instructions: "You are a coach.",
      input: [
        { role: "developer", content: "rules" },
        {
          role: "user",
          content: [
            { type: "input_text", text: "Review this set" },
            { type: "input_image", image_url: PNG },
          ],
        },
      ],
      reasoning: { effort: "medium" },
      max_output_tokens: 5000,
      text: { format: { type: "json_schema", name: "SetReview", schema: { type: "object" }, strict: true } },
    };
    const res = await coach(h, token, "set_review", request);
    assert.equal(res.status, 200);
    const sent = sentUpstream(h);
    assert.deepEqual(Object.keys(sent).sort(), [
      "input",
      "instructions",
      "max_output_tokens",
      "model",
      "reasoning",
      "store",
      "text",
    ]);
    assert.equal(sent.model, "muse-spark-1.2");
    assert.deepEqual(sent.input, request.input);
    assert.deepEqual(sent.text, { format: request.text.format });
  });

  it("passes the response body and status through", async () => {
    const { h, token } = await setup();
    const res = await coach(h, token, "debrief", { input: "hi" });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), OK_BODY);
    assert.match(res.headers.get("content-type") ?? "", /application\/json/);
    assert.match(res.headers.get("cache-control") ?? "", /no-store/);
  });

  it("returns 500 when the model key is not configured", async () => {
    const h = makeHarness({ env: { MODEL_API_KEY: undefined } });
    const token = await h.install();
    const err = await errorOf(await coach(h, token, "chat", { input: "hi" }));
    assert.deepEqual([err.status, err.code], [500, "server_misconfigured"]);
    assert.equal(h.calls.length, 0);
  });
});

describe("coach allowlists", () => {
  it("allows only muse-spark-1.3 and muse-spark-1.2", async () => {
    const { h, token } = await setup();
    for (const model of ["muse-spark-1.3", "muse-spark-1.2"]) {
      assert.equal((await coach(h, token, "chat", { model, input: "hi" })).status, 200, model);
      assert.equal(sentUpstream(h).model, model);
    }
    const before = h.calls.length;
    for (const model of ["muse-spark-1.1", "muse-spark-1.3-contributor", "muse-wonder-1.0", "muse-image-1.0", "", 7]) {
      const err = await errorOf(await coach(h, token, "chat", { model, input: "hi" }));
      assert.deepEqual([err.status, err.code], [400, "model_not_allowed"], String(model));
    }
    assert.equal(h.calls.length, before);
  });

  it("enforces the reasoning.effort allowlist per feature", async () => {
    const { h, token } = await setup();
    for (const feature of FEATURES) {
      const policy = POLICIES[feature];
      for (const effort of policy.efforts) {
        assert.equal((await coach(h, token, feature, { input: "hi", reasoning: { effort } })).status, 200);
        assert.deepEqual(sentUpstream(h).reasoning, { effort });
      }
      const rejected = ["none", "xhigh", "max", "", "LOW", 3].concat(
        ["minimal", "low", "medium", "high"].filter((e) => !policy.efforts.includes(e)),
      );
      for (const effort of rejected) {
        const err = await errorOf(await coach(h, token, feature, { input: "hi", reasoning: { effort } }));
        assert.deepEqual([err.status, err.code], [400, "effort_not_allowed"], `${feature}:${String(effort)}`);
      }
    }
    // Spot checks of the policy table: a set review is never allowed to think harder than medium.
    assert.ok(!POLICIES.set_review.efforts.includes("high"));
    assert.ok(POLICIES.debrief.efforts.includes("high"));
  });

  it("rejects unknown reasoning keys", async () => {
    const { h, token } = await setup();
    const err = await errorOf(await coach(h, token, "chat", { input: "hi", reasoning: { effort: "low", summary: "auto" } }));
    assert.deepEqual([err.status, err.code], [400, "unsupported_field"]);
  });

  it("clamps max_output_tokens into [4000, feature cap]", async () => {
    const { h, token } = await setup();
    for (const feature of FEATURES) {
      const policy = POLICIES[feature];
      const cases: [number, number][] = [
        [16, MIN_OUTPUT_TOKENS],
        [MIN_OUTPUT_TOKENS - 1, MIN_OUTPUT_TOKENS],
        [-5, MIN_OUTPUT_TOKENS],
        [policy.maxOutputTokens, policy.maxOutputTokens],
        [policy.maxOutputTokens + 1, policy.maxOutputTokens],
        [1_000_000, policy.maxOutputTokens],
      ];
      for (const [asked, expected] of cases) {
        const res = await coach(h, token, feature, { input: "hi", max_output_tokens: asked });
        assert.equal(res.status, 200, `${feature}:${asked}`);
        assert.equal(sentUpstream(h).max_output_tokens, expected, `${feature}:${asked}`);
      }
    }
    for (const bad of ["5000", 5000.5, null, true]) {
      const err = await errorOf(await coach(h, token, "chat", { input: "hi", max_output_tokens: bad }));
      assert.deepEqual([err.status, err.code], [400, "invalid_field"], String(bad));
    }
  });

  it("rejects fields outside the allowlist instead of forwarding them", async () => {
    const { h, token } = await setup();
    const extras: Record<string, unknown> = {
      previous_response_id: "resp_old",
      background: true,
      conversation: "conv_1",
      include: ["message.input_image.image_url"],
      metadata: { a: "b" },
      user: "someone",
      safety_identifier: "x",
      service_tier: "priority",
      temperature: 2,
      top_p: 1,
      prompt_cache_key: "k",
      max_tool_calls: 99,
      truncation: "auto",
    };
    for (const [key, value] of Object.entries(extras)) {
      const err = await errorOf(await coach(h, token, "chat", { input: "hi", [key]: value }));
      assert.deepEqual([err.status, err.code], [400, "unsupported_field"], key);
      assert.ok(err.message.includes(key));
    }
    assert.equal(h.calls.length, 0);
  });

  it("always forces store=false", async () => {
    const { h, token } = await setup();
    await coach(h, token, "chat", { input: "hi", store: true });
    assert.equal(sentUpstream(h).store, false);
  });

  it("requires input and validates its shape", async () => {
    const { h, token } = await setup();
    for (const body of [{}, { input: 5 }, { input: [] }, { input: [1] }, { input: [{ content: 5 }] }]) {
      const err = await errorOf(await coach(h, token, "chat", body));
      assert.deepEqual([err.status, err.code], [400, "invalid_field"], JSON.stringify(body));
    }
  });

  it("rejects non-JSON and non-object bodies", async () => {
    const { h, token } = await setup();
    for (const body of ["not json", "[1,2]", "null", '"str"', ""]) {
      const err = await errorOf(await coach(h, token, "chat", body));
      assert.deepEqual([err.status, err.code], [400, "invalid_json"], body);
    }
  });

  it("only allows function tools, and only for chat", async () => {
    const { h, token } = await setup();
    const fn = { type: "function", name: "get_sessions", description: "Recent sessions", parameters: { type: "object" }, extra: "dropped" };
    const loop = [
      { role: "user", content: "How did I do this week?" },
      { type: "function_call", call_id: "c1", name: "get_sessions", arguments: "{}" },
      { type: "function_call_output", call_id: "c1", output: "[]" },
    ];
    const ok = await coach(h, token, "chat", { input: loop, tools: [fn], tool_choice: "auto", parallel_tool_calls: false });
    assert.equal(ok.status, 200);
    const sent = sentUpstream(h);
    assert.deepEqual(sent.tools, [{ type: "function", name: "get_sessions", description: "Recent sessions", parameters: { type: "object" } }]);
    assert.equal(sent.tool_choice, "auto");
    assert.equal(sent.parallel_tool_calls, false);

    for (const tool of [{ type: "web_search" }, { type: "computer" }, { type: "function" }, "fn"]) {
      const err = await errorOf(await coach(h, token, "chat", { input: "hi", tools: [tool] }));
      assert.deepEqual([err.status, err.code], [400, "unsupported_tool"], JSON.stringify(tool));
    }
    for (const choice of ["required", "none", { type: "function", name: "x" }]) {
      const err = await errorOf(await coach(h, token, "chat", { input: "hi", tools: [fn], tool_choice: choice }));
      assert.equal(err.code, "invalid_field");
    }
    for (const feature of FEATURES.filter((f) => !POLICIES[f].allowTools)) {
      const err = await errorOf(await coach(h, token, feature, { input: "hi", tools: [fn] }));
      assert.deepEqual([err.status, err.code], [400, "tools_not_allowed"], feature);
    }
  });

  it("accepts only inline data-URL images within each feature's image limit", async () => {
    const { h, token } = await setup();
    const withImages = (n: number, url = PNG) => ({
      input: [{ role: "user", content: Array.from({ length: n }, () => ({ type: "input_image", image_url: url })) }],
    });
    for (const feature of FEATURES) {
      const max = POLICIES[feature].maxImages;
      if (max > 0) assert.equal((await coach(h, token, feature, withImages(max))).status, 200, feature);
      const err = await errorOf(await coach(h, token, feature, withImages(max + 1)));
      assert.deepEqual(
        [err.status, err.code],
        [400, max === 0 ? "images_not_allowed" : "too_many_images"],
        feature,
      );
    }
    for (const url of ["https://evil.example/x.png", "http://169.254.169.254/", "file:///etc/passwd", "data:text/plain;base64,AA=="]) {
      const err = await errorOf(await coach(h, token, "set_review", withImages(1, url)));
      assert.deepEqual([err.status, err.code], [400, "invalid_image_url"], url);
    }
    const fileId = { input: [{ role: "user", content: [{ type: "input_image", image_url: PNG, file_id: "file_1" }] }] };
    assert.equal((await errorOf(await coach(h, token, "set_review", fileId))).code, "invalid_image_url");
  });

  it("rejects file, audio, video and unknown input item types", async () => {
    const { h, token } = await setup();
    const parts = [
      { type: "input_file", file_id: "file_1" },
      { type: "input_audio", data: "AA==" },
      { type: "input_video", video_url: "https://x.example/v.mp4" },
      { type: "web_search_call" },
    ];
    for (const part of parts) {
      const err = await errorOf(await coach(h, token, "set_review", { input: [{ role: "user", content: [part] }] }));
      assert.deepEqual([err.status, err.code], [400, "unsupported_input_item"], part.type);
    }
    const item = await errorOf(await coach(h, token, "chat", { input: [{ type: "item_reference", id: "x" }] }));
    assert.equal(item.code, "unsupported_input_item");
  });

  it("validates text.format and drops other text keys", async () => {
    const { h, token } = await setup();
    const verbosity = await errorOf(await coach(h, token, "chat", { input: "hi", text: { verbosity: "high" } }));
    assert.equal(verbosity.code, "unsupported_field");
    const format = await errorOf(await coach(h, token, "chat", { input: "hi", text: { format: { type: "grammar" } } }));
    assert.equal(format.code, "invalid_field");
  });
});

describe("coach body cap", () => {
  function bodyOfSize(bytes: number): string {
    const prefix = '{"input":"';
    const suffix = '"}';
    return prefix + "a".repeat(bytes - prefix.length - suffix.length) + suffix;
  }

  it("rejects bodies over the feature cap with 413 and never calls upstream", async () => {
    const { h, token } = await setup();
    for (const feature of FEATURES) {
      const cap = POLICIES[feature].maxBodyBytes;
      const err = await errorOf(await coach(h, token, feature, bodyOfSize(cap + 1)));
      assert.deepEqual([err.status, err.code], [413, "payload_too_large"], feature);
    }
    assert.equal(h.calls.length, 0);
  });

  it("accepts a body exactly at the cap", async () => {
    const { h, token } = await setup();
    const cap = POLICIES.chat.maxBodyBytes;
    assert.equal((await coach(h, token, "chat", bodyOfSize(cap))).status, 200);
  });

  it("trusts a declared Content-Length over the stream", async () => {
    const { h, token } = await setup();
    const res = await coach(h, token, "chat", { input: "hi" }, { "content-length": String(POLICIES.chat.maxBodyBytes + 1) });
    assert.equal((await errorOf(res)).code, "payload_too_large");
    assert.equal(h.calls.length, 0);
  });

  it("stops reading a chunked body that has no Content-Length", async () => {
    const { h, token } = await setup();
    const chunk = new Uint8Array(64 * 1024).fill(97);
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        sent += 1;
        if (sent > 200) controller.close();
        else controller.enqueue(chunk);
      },
    });
    const res = await h.call("/v1/coach/responses", {
      token,
      method: "POST",
      body: stream,
      duplex: "half",
      headers: { "x-coach-feature": "chat", "content-type": "application/json" },
    } as RequestInit & { token: string });
    assert.equal((await errorOf(res)).code, "payload_too_large");
    assert.ok(sent < 20, `reader should stop early, pulled ${sent} chunks`);
    assert.equal(h.calls.length, 0);
  });

  it("gives meal photos a larger cap than text features", async () => {
    const { h, token } = await setup();
    const photo = (bytes: number) => ({
      input: [{ role: "user", content: [{ type: "input_image", image_url: `data:image/jpeg;base64,${"A".repeat(bytes)}` }] }],
    });
    assert.equal((await coach(h, token, "meal_photo", photo(2_700_000))).status, 200);
    assert.equal((await errorOf(await coach(h, token, "set_review", photo(2_700_000)))).code, "payload_too_large");
    assert.equal((await errorOf(await coach(h, token, "meal_photo", photo(4_300_000)))).code, "payload_too_large");
  });
});

describe("coach streaming", () => {
  const enc = new TextEncoder();

  it("rejects stream:true for features that do not allow it", async () => {
    const { h, token } = await setup();
    for (const feature of FEATURES) {
      const res = await coach(h, token, feature, { input: "hi", stream: true });
      if (POLICIES[feature].allowStream) {
        assert.equal(res.status, 200, feature);
        await res.arrayBuffer();
      } else {
        assert.deepEqual((await errorOf(res)).code, "stream_not_allowed", feature);
      }
    }
    const bad = await errorOf(await coach(h, token, "chat", { input: "hi", stream: "yes" }));
    assert.equal(bad.code, "invalid_field");
  });

  it("passes SSE chunks through before upstream has finished", async () => {
    const { h, token } = await setup();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let upstreamDone = false;
    h.upstream.handler = () => {
      const body = new ReadableStream<Uint8Array>({
        async start(controller) {
          controller.enqueue(enc.encode('data: {"type":"response.created"}\n\n'));
          controller.enqueue(enc.encode('data: {"type":"response.output_text.delta","delta":"Hel"}\n\n'));
          await gate;
          controller.enqueue(enc.encode('data: {"type":"response.output_text.delta","delta":"lo"}\n\n'));
          controller.enqueue(enc.encode("data: [DONE]\n\n"));
          upstreamDone = true;
          controller.close();
        },
      });
      return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
    };

    const res = await coach(h, token, "set_review", { input: "hi", stream: true });
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type") ?? "", /^text\/event-stream/);
    assert.match(res.headers.get("cache-control") ?? "", /no-store/);
    const sent = h.calls.at(-1);
    assert.equal(sent?.headers.get("accept"), "text/event-stream");
    assert.equal(JSON.parse(sent?.bodyText ?? "{}").stream, true);

    const reader = (res.body as ReadableStream<Uint8Array>).getReader();
    const decoder = new TextDecoder();
    let seen = decoder.decode((await reader.read()).value);
    // The first event is already in the app's hands while upstream is still blocked on the gate.
    assert.equal(upstreamDone, false);
    assert.match(seen, /response\.created/);
    assert.ok(seen.includes("\n\n"));

    release();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      seen += decoder.decode(value);
    }
    assert.equal(upstreamDone, true);
    assert.match(seen, /"delta":"Hel"/);
    assert.match(seen, /"delta":"lo"/);
    assert.ok(seen.endsWith("data: [DONE]\n\n"));
  });

  it("does not buffer the whole stream before responding", async () => {
    const { h, token } = await setup();
    const never = new Promise<void>(() => {});
    h.upstream.handler = () => {
      const body = new ReadableStream<Uint8Array>({
        async start(controller) {
          controller.enqueue(enc.encode("data: first\n\n"));
          await never;
        },
      });
      return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
    };
    const res = await coach(h, token, "chat", { input: "hi", stream: true });
    assert.equal(res.status, 200);
    const reader = (res.body as ReadableStream<Uint8Array>).getReader();
    const first = await reader.read();
    assert.equal(new TextDecoder().decode(first.value), "data: first\n\n");
    await reader.cancel();
  });
});

describe("coach upstream errors", () => {
  async function failWith(status: number, headers: Record<string, string> = {}, body: unknown = { error: { message: "nope" } }) {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream(body, status, headers);
    const res = await coach(h, token, "chat", { input: "hi" });
    return { h, res, err: await errorOf(res.clone()) };
  }

  it("passes an upstream 429 through with Retry-After", async () => {
    const { res, err } = await failWith(429, { "retry-after": "7" });
    assert.deepEqual([err.status, err.code], [429, "upstream_rate_limited"]);
    assert.equal(res.headers.get("retry-after"), "7");
  });

  it("supplies a default Retry-After and clamps absurd values", async () => {
    assert.equal((await failWith(429)).res.headers.get("retry-after"), "5");
    assert.equal((await failWith(429, { "retry-after": "999999" })).res.headers.get("retry-after"), "3600");
    const date = new Date(Date.UTC(2026, 9, 29, 12, 0, 42)).toUTCString();
    assert.equal((await failWith(429, { "retry-after": date })).res.headers.get("retry-after"), "42");
  });

  it("maps upstream 5xx sensibly", async () => {
    const unavailable = await failWith(503, { "retry-after": "60" });
    assert.deepEqual([unavailable.err.status, unavailable.err.code], [503, "upstream_unavailable"]);
    assert.equal(unavailable.res.headers.get("retry-after"), "60");
    assert.equal((await failWith(503)).res.headers.get("retry-after"), "30");
    assert.deepEqual([(await failWith(504)).err.status, (await failWith(504)).err.code], [504, "upstream_timeout"]);
    for (const status of [500, 502, 520]) {
      const { err } = await failWith(status);
      assert.deepEqual([err.status, err.code], [502, "upstream_error"], String(status));
    }
  });

  it("surfaces a sanitized upstream 400 message and keeps credential failures generic", async () => {
    const bad = await failWith(400, {}, { error: { message: "Invalid schema near LLM_123_abcdef", param: "text.format" } });
    assert.deepEqual([bad.err.status, bad.err.code], [400, "upstream_bad_request"]);
    assert.match(bad.err.message, /Invalid schema/);
    assert.ok(!bad.err.message.includes("LLM_123"));

    for (const status of [401, 402, 403]) {
      const { res, err } = await failWith(status, {}, { error: { message: `Incorrect key ${FAKE_MODEL_KEY}` } });
      assert.deepEqual([err.status, err.code], [502, "upstream_unauthorized"], String(status));
      assert.ok(!(await res.text()).includes("LLM_"));
    }
    assert.equal((await failWith(413)).err.code, "upstream_payload_too_large");
    assert.equal((await failWith(404)).err.code, "upstream_error");
  });

  it("returns 502 when upstream is unreachable", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => {
      throw new TypeError("fetch failed");
    };
    const err = await errorOf(await coach(h, token, "chat", { input: "hi" }));
    assert.deepEqual([err.status, err.code], [502, "upstream_unreachable"]);
  });

  it("times out and honours client disconnects while waiting for headers", async () => {
    const hang = (_url: string, init?: RequestInit) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(new Error("aborted")));
      });
    const makeCtx = (controller: AbortController): Ctx =>
      ({ request: new Request("https://x.test", { signal: controller.signal }), deps: { fetch: hang } }) as unknown as Ctx;

    await assert.rejects(
      fetchUpstream(makeCtx(new AbortController()), "https://u.test", {}, 20),
      (e: unknown) => e instanceof HttpError && e.status === 504 && e.code === "upstream_timeout",
    );
    const client = new AbortController();
    const pending = fetchUpstream(makeCtx(client), "https://u.test", {}, 60_000);
    client.abort();
    await assert.rejects(pending, (e: unknown) => e instanceof HttpError && e.code === "upstream_unreachable");
  });
});

describe("coach daily budget", () => {
  it("returns 429 with Retry-After until UTC midnight once the feature budget is spent", async () => {
    const { h, token } = await setup();
    const limit = POLICIES.spec_author.dailyRequests;
    for (let i = 0; i < limit; i += 1) {
      assert.equal((await coach(h, token, "spec_author", { input: "hi" })).status, 200, `request ${i + 1}`);
    }
    const before = h.calls.length;
    const res = await coach(h, token, "spec_author", { input: "hi" });
    const err = await errorOf(res.clone());
    assert.deepEqual([err.status, err.code], [429, "daily_budget_exceeded"]);
    assert.equal(res.headers.get("retry-after"), String(12 * 3600)); // harness clock is 12:00 UTC
    assert.equal(h.calls.length, before, "no upstream call once the budget is spent");
  });

  it("budgets each feature and each token separately", async () => {
    const { h, token } = await setup();
    const other = await h.install("203.0.113.2");
    const limit = POLICIES.spec_author.dailyRequests;
    for (let i = 0; i < limit; i += 1) await coach(h, token, "spec_author", { input: "hi" });
    assert.equal((await coach(h, token, "spec_author", { input: "hi" })).status, 429);
    assert.equal((await coach(h, token, "chat", { input: "hi" })).status, 200);
    assert.equal((await coach(h, other, "spec_author", { input: "hi" })).status, 200);
  });

  it("resets on the next UTC day", async () => {
    const { h, token } = await setup();
    const limit = POLICIES.spec_author.dailyRequests;
    for (let i = 0; i < limit; i += 1) await coach(h, token, "spec_author", { input: "hi" });
    assert.equal((await coach(h, token, "spec_author", { input: "hi" })).status, 429);
    h.clock.advance(12 * 3600 * 1000 + 1000); // 00:00:01 UTC
    assert.equal((await coach(h, token, "spec_author", { input: "hi" })).status, 200);
    const today = h.kv.keys().find((k) => k.endsWith(":spec_author:20261030"));
    const yesterday = h.kv.keys().find((k) => k.endsWith(":spec_author:20261029"));
    assert.equal(h.kv.store.get(today ?? "")?.value, "1", "the new day starts a fresh counter");
    assert.equal(h.kv.store.get(yesterday ?? "")?.value, String(limit));
  });

  it("does not charge malformed requests", async () => {
    const { h, token } = await setup();
    await coach(h, token, "chat", { input: "hi", model: "gpt-9" });
    await coach(h, token, "chat", "not json");
    await coach(h, token, "chat", { input: "hi", metadata: {} });
    await coach(h, token, "nope", { input: "hi" });
    assert.equal(budgetCount(h), 0);
    await coach(h, token, "chat", { input: "hi" });
    assert.equal(budgetCount(h), 1);
  });

  it("refunds the request when upstream fails", async () => {
    const { h, token } = await setup();
    await coach(h, token, "chat", { input: "hi" });
    assert.equal(budgetCount(h), 1);
    h.upstream.handler = () => jsonUpstream({ error: { message: "x" } }, 503);
    assert.equal((await coach(h, token, "chat", { input: "hi" })).status, 503);
    assert.equal(budgetCount(h), 1);
    h.upstream.handler = () => {
      throw new TypeError("down");
    };
    assert.equal((await coach(h, token, "chat", { input: "hi" })).status, 502);
    assert.equal(budgetCount(h), 1);
  });

  it("pins the policy numbers so changes are deliberate", () => {
    const table = Object.fromEntries(
      FEATURES.map((f) => {
        const p = POLICIES[f];
        return [
          f,
          {
            efforts: p.efforts.join("|"),
            defaultEffort: p.defaultEffort,
            maxTokens: [p.defaultMaxOutputTokens, p.maxOutputTokens],
            bodyKiB: p.maxBodyBytes / 1024,
            textKiB: p.maxTextBytes / 1024,
            images: p.maxImages,
            stream: p.allowStream,
            tools: p.allowTools,
            perDay: p.dailyRequests,
          },
        ];
      }),
    );
    assert.deepEqual(table, {
      set_review: { efforts: "minimal|low|medium", defaultEffort: "low", maxTokens: [4000, 6000], bodyKiB: 2048, textKiB: 128, images: 6, stream: true, tools: false, perDay: 120 },
      debrief: { efforts: "low|medium|high", defaultEffort: "medium", maxTokens: [6000, 8000], bodyKiB: 256, textKiB: 256, images: 0, stream: true, tools: false, perDay: 20 },
      chat: { efforts: "low|medium|high", defaultEffort: "medium", maxTokens: [6000, 8000], bodyKiB: 256, textKiB: 256, images: 0, stream: true, tools: true, perDay: 100 },
      meal_photo: { efforts: "minimal|low|medium", defaultEffort: "low", maxTokens: [4000, 6000], bodyKiB: 4096, textKiB: 64, images: 2, stream: false, tools: false, perDay: 40 },
      spec_author: { efforts: "low|medium|high", defaultEffort: "medium", maxTokens: [8000, 12000], bodyKiB: 3072, textKiB: 128, images: 8, stream: true, tools: false, perDay: 20 },
    });
    assert.equal(MIN_OUTPUT_TOKENS, 4000);
  });

  it("has a positive, bounded budget and token cap for every feature", () => {
    for (const feature of FEATURES as readonly Feature[]) {
      const p = POLICIES[feature];
      assert.ok(p.dailyRequests > 0 && p.dailyRequests <= 200, feature);
      assert.ok(p.maxTextBytes > 0 && p.maxTextBytes <= p.maxBodyBytes, feature);
      assert.ok(p.defaultMaxOutputTokens >= MIN_OUTPUT_TOKENS, feature);
      assert.ok(p.maxOutputTokens >= p.defaultMaxOutputTokens, feature);
      assert.ok(p.efforts.includes(p.defaultEffort), feature);
      assert.ok(!p.efforts.includes("xhigh") && !p.efforts.includes("max"), feature);
    }
  });
});

describe("coach input policy against hostile clients", () => {
  const dataImage = (chars = 0) => `data:image/png;base64,${"A".repeat(chars)}`;
  const toolOutput = (output: unknown) => ({ input: [{ type: "function_call_output", call_id: "call_1", output }] });

  it("applies the image rules to function_call_output.output as well as message content", async () => {
    const { h, token } = await setup();
    const remote = { type: "input_image", image_url: "https://evil.example/x.png" };
    const cases: [string, unknown, string][] = [
      ["remote image url", [remote], "invalid_image_url"],
      ["metadata endpoint", [{ type: "input_image", image_url: "http://169.254.169.254/latest/meta-data/" }], "invalid_image_url"],
      ["file id", [{ type: "input_image", image_url: PNG, file_id: "file_1" }], "invalid_image_url"],
      ["input_file with a url", [{ type: "input_file", file_url: "https://evil.example/big.pdf" }], "unsupported_input_item"],
      ["input_file with inline data", [{ type: "input_file", file_data: "AAAA" }], "unsupported_input_item"],
      ["input_video", [{ type: "input_video", video_url: "https://evil.example/v.mp4" }], "unsupported_input_item"],
      ["input_audio", [{ type: "input_audio", audio_url: "https://evil.example/a.wav" }], "unsupported_input_item"],
      ["non-object part", ["text"], "unsupported_input_item"],
      ["object output", { type: "input_text", text: "x" }, "invalid_field"],
      ["number output", 5, "invalid_field"],
    ];
    for (const [name, output, code] of cases) {
      const err = await errorOf(await coach(h, token, "chat", toolOutput(output)));
      assert.deepEqual([err.status, err.code], [400, code], name);
    }
    assert.equal(h.calls.length, 0, "nothing hostile reaches upstream");
  });

  it("counts images inside tool output against the feature's image limit", async () => {
    const { h, token } = await setup();
    // chat accepts no images at all, whether they arrive as message content or as tool output.
    const err = await errorOf(await coach(h, token, "chat", toolOutput([{ type: "input_image", image_url: PNG }])));
    assert.deepEqual([err.status, err.code], [400, "images_not_allowed"]);

    // set_review allows 6: mixing content and output images shares one count.
    const image = { type: "input_image", image_url: PNG };
    const mixed = (inContent: number, inOutput: number) => ({
      input: [
        { role: "user", content: Array.from({ length: inContent }, () => image) },
        { type: "function_call_output", call_id: "c", output: Array.from({ length: inOutput }, () => image) },
      ],
    });
    assert.equal((await coach(h, token, "set_review", mixed(3, 3))).status, 200);
    const over = await errorOf(await coach(h, token, "set_review", mixed(3, 4)));
    assert.deepEqual([over.status, over.code], [400, "too_many_images"]);
  });

  it("still accepts ordinary tool output and the item shapes a chat loop replays", async () => {
    const { h, token } = await setup();
    const bodies: unknown[] = [
      toolOutput("{\"sessions\":3}"),
      toolOutput([{ type: "input_text", text: "3 sessions" }]),
      {
        input: [
          { role: "user", content: "How did I do?" },
          { type: "reasoning", id: "rs_1", summary: [{ type: "summary_text", text: "thinking" }], content: [{ type: "reasoning_text", text: "..." }] },
          { type: "function_call", call_id: "call_1", name: "get_sessions", arguments: "{\"days\":7}" },
          { type: "function_call_output", call_id: "call_1", output: "{\"sessions\":3}" },
          { type: "message", role: "assistant", content: [{ type: "output_text", text: "Three sessions." }] },
        ],
      },
    ];
    for (const body of bodies) assert.equal((await coach(h, token, "chat", body)).status, 200, JSON.stringify(body).slice(0, 60));
    // The input reaches upstream unchanged.
    assert.deepEqual(sentUpstream(h).input, (bodies[2] as { input: unknown }).input);
  });

  it("caps text separately from inline images", async () => {
    const { h, token } = await setup();
    const withText = (bytes: number) => ({ input: [{ role: "user", content: [{ type: "input_text", text: "a".repeat(bytes) }] }] });
    for (const feature of ["set_review", "meal_photo", "spec_author"] as const) {
      const cap = POLICIES[feature].maxTextBytes;
      assert.ok(cap < POLICIES[feature].maxBodyBytes, feature);
      assert.equal((await coach(h, token, feature, withText(cap - 1024))).status, 200, `${feature} just under`);
      const over = await errorOf(await coach(h, token, feature, withText(cap + 1024)));
      assert.deepEqual([over.status, over.code], [413, "payload_too_large"], `${feature} just over`);
    }
    const calls = h.calls.length;
    // Text hidden in other fields counts too.
    const instructions = { input: "hi", instructions: "a".repeat(POLICIES.set_review.maxTextBytes + 1024) };
    assert.equal((await errorOf(await coach(h, token, "set_review", instructions))).code, "payload_too_large");
    assert.equal(h.calls.length, calls, "over-long text never reaches upstream");
  });

  it("lets large photos through as long as the text is small, and bills nothing for refusals", async () => {
    const { h, token } = await setup();
    const photo = { type: "input_image", image_url: dataImage(1_500_000) };
    const body = { input: [{ role: "user", content: [{ type: "input_text", text: "estimate this meal" }, photo] }] };
    assert.equal((await coach(h, token, "meal_photo", body)).status, 200);

    const before = h.kv.writes;
    const big = { input: [{ role: "user", content: [{ type: "input_text", text: "a".repeat(80 * 1024) }, photo] }] };
    assert.equal((await errorOf(await coach(h, token, "meal_photo", big))).code, "payload_too_large");
    assert.equal(h.kv.writes, before, "a refused request is not charged");
  });

  it("rejects prototype-pollution style keys instead of forwarding them", async () => {
    const { h, token } = await setup();
    for (const raw of [
      '{"input":"hi","__proto__":{"store":true}}',
      '{"input":"hi","constructor":{"prototype":{"store":true}}}',
      '{"input":"hi","reasoning":{"__proto__":{"effort":"max"}}}',
      '{"input":"hi","text":{"__proto__":{"verbosity":"high"}}}',
    ]) {
      const err = await errorOf(await coach(h, token, "chat", raw));
      assert.deepEqual([err.status, err.code], [400, "unsupported_field"], raw);
    }
    assert.equal(h.calls.length, 0);
  });

  it("survives pathologically nested JSON at the body cap without crashing", async () => {
    const { h, token } = await setup();
    const depth = 120_000;
    const nested = `${"[".repeat(depth)}1${"]".repeat(depth)}`;
    const body = `{"input":"hi","text":{"format":{"type":"json_schema","schema":${nested}}}}`;
    assert.ok(body.length < POLICIES.debrief.maxBodyBytes);
    const res = await coach(h, token, "debrief", body);
    assert.equal(res.status, 200);
    assert.equal(sentUpstream(h).store, false);
  });

  it("forces the safe defaults even when the client sends the dangerous values", async () => {
    const { h, token } = await setup();
    await coach(h, token, "set_review", {
      input: "hi",
      store: true,
      stream: false,
      reasoning: { effort: "medium" },
      max_output_tokens: 10_000_000,
    });
    const sent = sentUpstream(h);
    assert.equal(sent.store, false);
    assert.equal(sent.max_output_tokens, POLICIES.set_review.maxOutputTokens);
    assert.deepEqual(sent.reasoning, { effort: "medium" });
    for (const effort of ["xhigh", "max", "none", "HIGH", " low", "", null, 3, ["low"], { effort: "low" }]) {
      const err = await errorOf(await coach(h, token, "debrief", { input: "hi", reasoning: { effort } }));
      assert.equal(err.code, "effort_not_allowed", JSON.stringify(effort));
    }
    for (const literal of ["1.5", '"6000"', "null", "1e999", "[6000]", "{}", "true"]) {
      const err = await errorOf(await coach(h, token, "debrief", `{"input":"hi","max_output_tokens":${literal}}`));
      assert.equal(err.code, "invalid_field", literal);
    }
  });
});

describe("coach streaming passes upstream failures through untouched", () => {
  it("delivers in-stream failure events inside the 200, byte for byte", async () => {
    const { h, token } = await setup();
    const events =
      'data: {"type":"response.output_text.delta","delta":"Hel"}\n\n' +
      'data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"sanitized"}}}\n\n' +
      'data: {"type":"error","code":"server_shutting_down","message":"retry"}\n\n' +
      "data: [DONE]\n\n";
    h.upstream.handler = () => new Response(events, { status: 200, headers: { "content-type": "text/event-stream" } });
    const res = await coach(h, token, "chat", { input: "hi", stream: true });
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type") ?? "", /^text\/event-stream/);
    assert.match(res.headers.get("cache-control") ?? "", /no-transform/);
    assert.equal(await res.text(), events);
    assert.equal(budgetCount(h), 1, "a stream that already started is not refunded");
  });

  it("sends Accept: text/event-stream upstream only when streaming", async () => {
    const { h, token } = await setup();
    await coach(h, token, "chat", { input: "hi", stream: true });
    assert.equal(h.calls.at(-1)?.headers.get("accept"), "text/event-stream");
    assert.equal(sentUpstream(h).stream, true);
    await coach(h, token, "chat", { input: "hi" });
    assert.equal(h.calls.at(-1)?.headers.get("accept"), "application/json");
    assert.equal("stream" in sentUpstream(h), false);
  });
});
