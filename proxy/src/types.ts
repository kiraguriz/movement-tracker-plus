// Minimal structural types so the Worker needs no @cloudflare/workers-types dependency.

export interface KVLike {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
  delete(key: string): Promise<void>;
}

export interface Env {
  PROXY_KV: KVLike;
  KILL_SWITCH?: string;
  MUSE_BASE_URL?: string;
  // Secrets: never committed, never logged.
  MODEL_API_KEY?: string;
  USDA_API_KEY?: string;
}

export interface CacheLike {
  match(request: Request): Promise<Response | undefined>;
  put(request: Request, response: Response): Promise<void>;
}

export interface ExecCtx {
  waitUntil(promise: Promise<unknown>): void;
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

// The only thing ever logged: no bodies, tokens, keys, query strings.
export interface LogEntry {
  route: string;
  status: number;
  ms: number;
  feature?: string;
}

export interface Deps {
  fetch: FetchLike;
  now: () => number;
  randomBytes: (length: number) => Uint8Array;
  getCache: () => CacheLike | null;
  log: (entry: LogEntry) => void;
}

// Per-isolate mutable state: positive token lookups and the isolate's own view of each counter.
export interface State {
  tokenCache: Map<string, number>;
  counts: Map<string, { n: number; expiresAt: number }>;
}

export interface Ctx {
  request: Request;
  url: URL;
  env: Env;
  exec: ExecCtx;
  deps: Deps;
  state: State;
  // Set by the dispatcher after authentication: first 32 hex chars of SHA-256(token).
  tokenId: string;
  // Filled by handlers so the request log can include the coach feature.
  meta: { feature?: string };
}
