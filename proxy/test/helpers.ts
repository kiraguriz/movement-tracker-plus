import { createApp } from "../src/app.ts";
import type { CacheLike, Deps, Env, ExecCtx, FetchLike, KVLike, LogEntry } from "../src/types.ts";

export const BASE = "https://proxy.test";
export const FAKE_MODEL_KEY = "LLM_000_FAKE_MODEL_KEY_FOR_TESTS";
export const FAKE_USDA_KEY = "FAKE_USDA_KEY_FOR_TESTS";
export const MUSE_BASE = "https://muse.test/v1";

// 2026-10-29T12:00:00Z
export const START_MS = Date.UTC(2026, 9, 29, 12, 0, 0);

export class Clock {
  t: number;
  constructor(t: number = START_MS) {
    this.t = t;
  }
  now = (): number => this.t;
  advance(ms: number): void {
    this.t += ms;
  }
}

interface Entry {
  value: string;
  expiresAt: number | null;
}

const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 1));

export class MemoryKV implements KVLike {
  store = new Map<string, Entry>();
  reads = 0;
  writes = 0;
  readKeys: string[] = [];
  clock: Clock;
  // Real KV answers in milliseconds, which lets parallel requests interleave between read and write.
  latency = false;
  // Real KV rejects a second write to the same key within a second. 0 turns the rule off.
  minWriteGapMs = 0;
  private lastWrite = new Map<string, number>();

  constructor(clock: Clock) {
    this.clock = clock;
  }

  async get(key: string): Promise<string | null> {
    if (this.latency) await tick();
    this.reads += 1;
    this.readKeys.push(key);
    const entry = this.store.get(key);
    if (!entry) return null;
    if (entry.expiresAt !== null && entry.expiresAt <= this.clock.t) {
      this.store.delete(key);
      return null;
    }
    return entry.value;
  }

  async put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void> {
    if (this.latency) await tick();
    if (this.minWriteGapMs > 0) {
      const last = this.lastWrite.get(key);
      if (last !== undefined && this.clock.t - last < this.minWriteGapMs) {
        throw new Error("KV PUT failed: 429 Too Many Requests");
      }
      this.lastWrite.set(key, this.clock.t);
    }
    this.writes += 1;
    const ttl = options?.expirationTtl;
    if (ttl !== undefined && ttl < 60) throw new Error("KV minimum expirationTtl is 60 seconds");
    this.store.set(key, { value, expiresAt: ttl === undefined ? null : this.clock.t + ttl * 1000 });
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }

  keys(): string[] {
    return [...this.store.keys()];
  }

  dump(): string {
    return JSON.stringify([...this.store.entries()]);
  }
}

export class MemoryCache implements CacheLike {
  entries = new Map<string, string>();
  matches = 0;
  puts = 0;
  failMatch = false;

  async match(request: Request): Promise<Response | undefined> {
    this.matches += 1;
    if (this.failMatch) throw new Error("cache unavailable");
    const hit = this.entries.get(request.url);
    return hit === undefined
      ? undefined
      : new Response(hit, { headers: { "content-type": "application/json" } });
  }

  async put(request: Request, response: Response): Promise<void> {
    this.puts += 1;
    this.entries.set(request.url, await response.text());
  }
}

export interface UpstreamCall {
  url: string;
  method: string;
  redirect: string;
  headers: Headers;
  body: Uint8Array;
  bodyText: string;
}

export type UpstreamHandler = (call: UpstreamCall) => Response | Promise<Response>;

export interface Harness {
  app: ReturnType<typeof createApp>;
  kv: MemoryKV;
  cache: MemoryCache;
  clock: Clock;
  env: Env;
  calls: UpstreamCall[];
  logs: LogEntry[];
  // Set the handler that answers upstream (Meta or USDA) requests.
  upstream: { handler: UpstreamHandler };
  pending: Promise<unknown>[];
  call(path: string, init?: RequestInit & { token?: string; ip?: string; headers?: Record<string, string> }): Promise<Response>;
  flush(): Promise<void>;
  install(ip?: string): Promise<string>;
}

export function makeHarness(options: { env?: Partial<Env>; cache?: boolean } = {}): Harness {
  const clock = new Clock();
  const kv = new MemoryKV(clock);
  const cache = new MemoryCache();
  const calls: UpstreamCall[] = [];
  const logs: LogEntry[] = [];
  const upstream = {
    handler: (() => new Response("{}", { headers: { "content-type": "application/json" } })) as UpstreamHandler,
  };
  const pending: Promise<unknown>[] = [];

  const fakeFetch: FetchLike = async (input, init) => {
    const request = new Request(input, init);
    const body = new Uint8Array(await request.arrayBuffer());
    const call: UpstreamCall = {
      url: request.url,
      method: request.method,
      redirect: request.redirect,
      headers: request.headers,
      body,
      bodyText: new TextDecoder().decode(body),
    };
    calls.push(call);
    return upstream.handler(call);
  };

  let counter = 0;
  const deps: Deps = {
    fetch: fakeFetch,
    now: clock.now,
    randomBytes: (length) => {
      // Deterministic but distinct per call, and varied across bytes.
      counter += 1;
      const out = new Uint8Array(length);
      for (let i = 0; i < length; i += 1) out[i] = (counter * 31 + i * 7 + 13) % 256;
      return out;
    },
    getCache: () => (options.cache === false ? null : cache),
    log: (entry) => logs.push(entry),
  };

  const env: Env = {
    PROXY_KV: kv,
    KILL_SWITCH: "0",
    MUSE_BASE_URL: MUSE_BASE,
    MODEL_API_KEY: FAKE_MODEL_KEY,
    USDA_API_KEY: FAKE_USDA_KEY,
    ...options.env,
  };

  const app = createApp(deps);
  const exec: ExecCtx = { waitUntil: (promise) => void pending.push(promise) };

  const harness: Harness = {
    app,
    kv,
    cache,
    clock,
    env,
    calls,
    logs,
    upstream,
    pending,
    async call(path, init = {}) {
      const { token, ip, headers: extra, ...rest } = init;
      const headers = new Headers(extra ?? {});
      if (token) headers.set("authorization", `Bearer ${token}`);
      if (ip) headers.set("cf-connecting-ip", ip);
      return app.fetch(new Request(`${BASE}${path}`, { ...rest, headers }), env, exec);
    },
    async flush() {
      await Promise.all(pending.splice(0));
    },
    async install(ip = "203.0.113.1") {
      const res = await harness.call("/v1/install", { method: "POST", ip });
      if (res.status !== 201) throw new Error(`install failed: ${res.status}`);
      const body = (await res.json()) as { token: string };
      return body.token;
    },
  };
  return harness;
}

export function jsonUpstream(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

export function post(path: string, body: unknown, headers: Record<string, string> = {}): [string, RequestInit] {
  return [path, { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json", ...headers } }];
}

export async function errorOf(res: Response): Promise<{ status: number; code: string; message: string }> {
  const body = (await res.json()) as { error: { code: string; message: string } };
  return { status: res.status, code: body.error.code, message: body.error.message };
}
