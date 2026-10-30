import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { VOICE_DAILY_REQUESTS, VOICE_MAX_BODY_BYTES, VOICE_MODEL } from "../src/voice.ts";
import { FAKE_MODEL_KEY, MUSE_BASE, errorOf, jsonUpstream, makeHarness } from "./helpers.ts";
import type { Harness } from "./helpers.ts";

const TRANSCRIPT = { sessionId: "s1", transcript: "three sets of squats", audioDurationMs: 8240, turns: [] };

// 60 s of 16 kHz mono 16-bit PCM plus the 44-byte header.
const SIXTY_SECONDS_16K = 60 * 16_000 * 2 + 44;

function wav(bytes: number): Uint8Array {
  const out = new Uint8Array(bytes);
  out.set(new TextEncoder().encode("RIFF"), 0);
  out.set(new TextEncoder().encode("WAVE"), 8);
  for (let i = 44; i < bytes; i += 1) out[i] = (i * 31) % 251;
  return out;
}

function form(audio: Uint8Array | string | null, request?: unknown): FormData {
  const fd = new FormData();
  if (request !== undefined) {
    const text = typeof request === "string" ? request : JSON.stringify(request);
    fd.append("request", new Blob([text], { type: "application/json" }));
  }
  if (typeof audio === "string") fd.append("audio", audio);
  else if (audio) fd.append("audio", new Blob([audio as BlobPart], { type: "audio/wav" }), "note.wav");
  return fd;
}

async function setup(): Promise<{ h: Harness; token: string }> {
  const h = makeHarness();
  const token = await h.install();
  h.upstream.handler = () => jsonUpstream(TRANSCRIPT);
  return { h, token };
}

function transcribe(h: Harness, token: string, body: BodyInit | null, headers: Record<string, string> = {}) {
  return h.call("/v1/voice/transcribe", { token, method: "POST", body, headers });
}

async function sentForm(h: Harness): Promise<FormData> {
  const call = h.calls.at(-1);
  assert.ok(call);
  const contentType = call.headers.get("content-type") ?? "";
  assert.match(contentType, /^multipart\/form-data; boundary=/);
  return new Response(call.body as BodyInit, { headers: { "content-type": contentType } }).formData();
}

describe("voice transcribe", () => {
  it("forwards a multipart request to {MUSE_BASE_URL}/asr/transcribe with the server key", async () => {
    const { h, token } = await setup();
    const audio = wav(32_044);
    const res = await transcribe(h, token, form(audio, { mode: "ENDPOINTING" }));
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), TRANSCRIPT);

    const call = h.calls.at(-1);
    assert.equal(call?.url, `${MUSE_BASE}/asr/transcribe`);
    assert.equal(call?.method, "POST");
    assert.equal(call?.headers.get("authorization"), `Bearer ${FAKE_MODEL_KEY}`);
    assert.equal(call?.headers.get("accept"), "application/json");
    assert.ok(!call?.bodyText.includes(token));

    const upstream = await sentForm(h);
    assert.deepEqual(JSON.parse(String(upstream.get("request"))), {
      model: VOICE_MODEL,
      audioEncoding: "WAV",
      mode: "ENDPOINTING",
    });
    const sentAudio = upstream.get("audio");
    assert.ok(sentAudio && typeof sentAudio !== "string");
    assert.equal(sentAudio.type, "audio/wav");
    assert.deepEqual(new Uint8Array(await sentAudio.arrayBuffer()), audio);
  });

  it("defaults the settings when the request part is omitted", async () => {
    const { h, token } = await setup();
    assert.equal((await transcribe(h, token, form(wav(2044)))).status, 200);
    const upstream = await sentForm(h);
    assert.deepEqual(JSON.parse(String(upstream.get("request"))), {
      model: VOICE_MODEL,
      audioEncoding: "WAV",
      mode: "PUSH_TO_TALK",
    });
  });

  it("fixes model and encoding and drops unknown settings", async () => {
    const { h, token } = await setup();
    const settings = {
      model: "muse-spark-1.3",
      audioEncoding: "MP3",
      mode: "PUSH_TO_TALK",
      languageBias: ["English", "Mandarin"],
      keywords: ["goblet squat"],
      partialMode: "DELTA",
      emitAudioProgress: true,
      sessionId: "attacker",
      authorization: { accessToken: "x" },
    };
    assert.equal((await transcribe(h, token, form(wav(2044), settings))).status, 200);
    const upstream = await sentForm(h);
    assert.deepEqual(JSON.parse(String(upstream.get("request"))), {
      model: VOICE_MODEL,
      audioEncoding: "WAV",
      mode: "PUSH_TO_TALK",
      languageBias: ["English", "Mandarin"],
      keywords: ["goblet squat"],
    });
    assert.ok(!h.calls.at(-1)?.url.includes("attacker"));
  });

  it("rejects invalid settings", async () => {
    const { h, token } = await setup();
    const bad: [unknown, string][] = [
      [{ mode: "DIARIZATION" }, "invalid_field"],
      [{ mode: 3 }, "invalid_field"],
      [{ languageBias: "English" }, "invalid_field"],
      [{ languageBias: ["a", "b", "c", "d", "e", "f"] }, "invalid_field"],
      [{ keywords: [1] }, "invalid_field"],
      [["not", "an", "object"], "invalid_field"],
      ["{not json", "invalid_json"],
    ];
    for (const [settings, code] of bad) {
      const err = await errorOf(await transcribe(h, token, form(wav(2044), settings)));
      assert.deepEqual([err.status, err.code], [400, code], JSON.stringify(settings));
    }
    assert.equal(h.calls.length, 0);
  });

  it("requires multipart/form-data with a WAV `audio` file", async () => {
    const { h, token } = await setup();
    const json = await errorOf(await transcribe(h, token, "{}", { "content-type": "application/json" }));
    assert.deepEqual([json.status, json.code], [400, "invalid_content_type"]);

    const garbage = await errorOf(await transcribe(h, token, "garbage", { "content-type": "multipart/form-data; boundary=zzz" }));
    assert.deepEqual([garbage.status, garbage.code], [400, "invalid_multipart"]);

    const missing = await errorOf(await transcribe(h, token, form(null, {})));
    assert.deepEqual([missing.status, missing.code], [400, "invalid_multipart"]);

    const textField = await errorOf(await transcribe(h, token, form("RIFF....WAVE")));
    assert.deepEqual([textField.status, textField.code], [400, "invalid_multipart"]);

    const notWav = new Uint8Array(4096).fill(1);
    const wrongType = await errorOf(await transcribe(h, token, form(notWav)));
    assert.deepEqual([wrongType.status, wrongType.code], [400, "invalid_audio"]);

    const truncated = await errorOf(await transcribe(h, token, form(wav(20))));
    assert.equal(truncated.code, "invalid_audio");
    assert.equal(h.calls.length, 0);
  });

  it("accepts 60 s of 16 kHz mono WAV and rejects anything over the 2 MiB cap", async () => {
    const { h, token } = await setup();
    assert.equal(VOICE_MAX_BODY_BYTES, 2 * 1024 * 1024);
    assert.ok(SIXTY_SECONDS_16K < VOICE_MAX_BODY_BYTES);
    assert.equal((await transcribe(h, token, form(wav(SIXTY_SECONDS_16K)))).status, 200);

    const before = h.calls.length;
    // Literal size on purpose: ~2.2 MB must be refused whatever the constant says.
    const over = await transcribe(h, token, form(wav(2_200_000)));
    const err = await errorOf(over);
    assert.deepEqual([err.status, err.code], [413, "payload_too_large"]);
    assert.equal(h.calls.length, before, "oversized audio never reaches upstream");
  });

  it("trusts a declared Content-Length over the stream", async () => {
    const { h, token } = await setup();
    const res = await transcribe(h, token, form(wav(2044)), { "content-length": "2200000" });
    assert.equal((await errorOf(res)).code, "payload_too_large");
    assert.equal(h.calls.length, 0);
  });

  it("passes an upstream 429 through with Retry-After and refunds the budget", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream({ error: { message: "slow down" } }, 429, { "retry-after": "12" });
    const res = await transcribe(h, token, form(wav(2044)));
    const err = await errorOf(res.clone());
    assert.deepEqual([err.status, err.code], [429, "upstream_rate_limited"]);
    assert.equal(res.headers.get("retry-after"), "12");
    const key = h.kv.keys().find((k) => k.startsWith("bud:"));
    assert.equal(h.kv.store.get(key ?? "")?.value, "0");
  });

  it("maps other upstream failures", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream({ error: { message: "bad wav" } }, 400);
    const bad = await errorOf(await transcribe(h, token, form(wav(2044))));
    assert.deepEqual([bad.status, bad.code, bad.message], [400, "upstream_bad_request", "bad wav"]);
    h.upstream.handler = () => jsonUpstream({}, 500);
    assert.equal((await errorOf(await transcribe(h, token, form(wav(2044))))).code, "upstream_error");
  });

  it("has its own daily budget", async () => {
    const { h, token } = await setup();
    for (let i = 0; i < VOICE_DAILY_REQUESTS; i += 1) {
      assert.equal((await transcribe(h, token, form(wav(2044)))).status, 200, `request ${i + 1}`);
    }
    const res = await transcribe(h, token, form(wav(2044)));
    assert.equal((await errorOf(res.clone())).code, "daily_budget_exceeded");
    assert.equal(res.headers.get("retry-after"), String(12 * 3600));
    // Coach budgets are separate.
    h.upstream.handler = () => jsonUpstream({ output: [] });
    const coach = await h.call("/v1/coach/responses", {
      token,
      method: "POST",
      body: JSON.stringify({ input: "hi" }),
      headers: { "x-coach-feature": "chat" },
    });
    assert.equal(coach.status, 200);
  });

  it("returns 500 when the model key is not configured", async () => {
    const h = makeHarness({ env: { MODEL_API_KEY: undefined } });
    const token = await h.install();
    const err = await errorOf(await transcribe(h, token, form(wav(2044))));
    assert.deepEqual([err.status, err.code], [500, "server_misconfigured"]);
  });
});

describe("voice multipart edge cases", () => {
  const encoder = new TextEncoder();

  function raw(boundary: string, parts: { headers: string; body: string | Uint8Array }[]): Uint8Array {
    const chunks: Uint8Array[] = [];
    for (const part of parts) {
      chunks.push(encoder.encode(`--${boundary}\r\n${part.headers}\r\n\r\n`));
      chunks.push(typeof part.body === "string" ? encoder.encode(part.body) : part.body);
      chunks.push(encoder.encode("\r\n"));
    }
    chunks.push(encoder.encode(`--${boundary}--\r\n`));
    const out = new Uint8Array(chunks.reduce((n, c) => n + c.byteLength, 0));
    let offset = 0;
    for (const c of chunks) {
      out.set(c, offset);
      offset += c.byteLength;
    }
    return out;
  }
  const audioPart = (bytes: Uint8Array) => ({
    headers: 'Content-Disposition: form-data; name="audio"; filename="a.wav"\r\nContent-Type: audio/wav',
    body: bytes,
  });

  it("forwards exactly one request part and one audio part, whatever else the client adds", async () => {
    const { h, token } = await setup();
    const fd = form(wav(2044), { mode: "ENDPOINTING" });
    fd.append("model", "muse-voice-transcribe-1.0-contributor");
    fd.append("sessionId", "attacker-chosen");
    fd.append("file", new Blob(["x".repeat(1000)]), "extra.bin");
    fd.append("audio", new Blob([wav(5000) as BlobPart], { type: "audio/wav" }), "second.wav");
    assert.equal((await transcribe(h, token, fd)).status, 200);
    const sent = await sentForm(h);
    assert.deepEqual([...sent.keys()], ["request", "audio"]);
    assert.equal(h.calls.at(-1)?.url.includes("sessionId"), false);
    const audio = sent.get("audio");
    assert.ok(audio && typeof audio !== "string");
    assert.equal(audio.size, 2044, "the first audio part is the one forwarded");
    assert.equal(JSON.parse(String(await new Response(sent.get("request") as Blob).text())).model, VOICE_MODEL);
  });

  it("validates the first audio part, so a valid second part cannot smuggle bytes past the check", async () => {
    const { h, token } = await setup();
    const fd = new FormData();
    fd.append("audio", new Blob(["MZ not a wav"], { type: "audio/wav" }), "a.wav");
    fd.append("audio", new Blob([wav(100) as BlobPart], { type: "audio/wav" }), "b.wav");
    assert.equal((await errorOf(await transcribe(h, token, fd))).code, "invalid_audio");
    assert.equal(h.calls.length, 0);
  });

  it("stops reading a chunked body that has no Content-Length once it passes the cap", async () => {
    const { h, token } = await setup();
    let pulled = 0;
    const chunk = new Uint8Array(64 * 1024).fill(97);
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulled += chunk.byteLength;
        controller.enqueue(chunk);
        if (pulled > 64 * 1024 * 1024) controller.close();
      },
    });
    const res = await h.call("/v1/voice/transcribe", {
      token,
      method: "POST",
      body: stream,
      duplex: "half",
      headers: { "content-type": "multipart/form-data; boundary=zz" },
    } as RequestInit);
    assert.equal((await errorOf(res)).code, "payload_too_large");
    assert.ok(pulled < 4 * VOICE_MAX_BODY_BYTES, `read ${pulled} bytes`);
    assert.equal(h.calls.length, 0);
  });

  it("handles a body made of thousands of tiny parts within the cap", async () => {
    const { h, token } = await setup();
    const parts = Array.from({ length: 20_000 }, (_, i) => ({ headers: `Content-Disposition: form-data; name="p${i}"`, body: "x" }));
    parts.push(audioPart(wav(100)) as never);
    const body = raw("b0und", parts);
    assert.ok(body.byteLength < VOICE_MAX_BODY_BYTES);
    const started = Date.now();
    const res = await transcribe(h, token, body as BodyInit, { "content-type": "multipart/form-data; boundary=b0und" });
    assert.equal(res.status, 200);
    assert.ok(Date.now() - started < 2000, "parsing stays cheap");
    assert.deepEqual([...(await sentForm(h)).keys()], ["request", "audio"]);
  });

  it("rejects malformed multipart bodies without calling upstream", async () => {
    const { h, token } = await setup();
    const attempts: [string, BodyInit, string][] = [
      ["wrong boundary", raw("one", [audioPart(wav(100))]) as BodyInit, "multipart/form-data; boundary=two"],
      ["no closing boundary", encoder.encode('--b\r\nContent-Disposition: form-data; name="audio"\r\n\r\nRIFF') as BodyInit, "multipart/form-data; boundary=b"],
      ["json instead of multipart", JSON.stringify({ audio: "RIFF" }), "application/json"],
      ["urlencoded", "audio=RIFF", "application/x-www-form-urlencoded"],
      ["empty body", "", "multipart/form-data; boundary=b"],
    ];
    for (const [name, body, contentType] of attempts) {
      const res = await transcribe(h, token, body, { "content-type": contentType });
      assert.equal(res.status, 400, name);
      assert.match((await errorOf(res)).code, /^invalid_/, name);
    }
    assert.equal(h.calls.length, 0);
  });

  it("limits the optional settings", async () => {
    const { h, token } = await setup();
    const bad: unknown[] = [
      { mode: "DIARIZATION" },
      { mode: ["PUSH_TO_TALK"] },
      { languageBias: ["English", "French", "German", "Italian", "Spanish", "Dutch"] },
      { languageBias: "English" },
      { languageBias: [""] },
      { keywords: Array.from({ length: 51 }, (_, i) => `k${i}`) },
      { keywords: ["x".repeat(65)] },
      { keywords: [{ a: 1 }] },
      [],
      "text",
      null,
    ];
    for (const settings of bad) {
      const fd = new FormData();
      fd.append("request", new Blob([JSON.stringify(settings)], { type: "application/json" }));
      fd.append("audio", new Blob([wav(100) as BlobPart], { type: "audio/wav" }), "a.wav");
      const res = await transcribe(h, token, fd);
      assert.equal(res.status, 400, JSON.stringify(settings));
    }
    assert.equal(h.calls.length, 0);
  });
});
