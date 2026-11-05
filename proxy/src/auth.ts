import { HttpError, base64url, jsonResponse, sha256Hex } from "./http.ts";
import { bumpCounter, secondsToNextHour } from "./budget.ts";
import type { Ctx } from "./types.ts";

// Install tokens are 256-bit random values, base64url without padding (43 characters).
const TOKEN_BYTES = 32;
const TOKEN_RE = /^bearer ([A-Za-z0-9_-]{43})$/i;

// Tokens expire in KV after this long; the app re-installs when it sees 401 invalid_token.
export const TOKEN_TTL_SECONDS = 120 * 24 * 60 * 60;

// Positive lookups are cached per isolate. A revoked token keeps working here for at most this long.
export const TOKEN_CACHE_TTL_MS = 5 * 60 * 1000;
const TOKEN_CACHE_MAX_ENTRIES = 2000;

export const INSTALL_LIMIT_PER_HOUR = 5;

// The install limit is keyed per network, not per address. IPv6 is keyed per /56: residential
// allocations are typically a /56 (256 /64s), so a /64 key would let one subscriber mint 256x the
// tokens, while a /48 would lump unrelated mobile users together.
export function networkKey(ip: string): string {
  const raw = ip.trim().toLowerCase();
  if (!raw.includes(":")) return raw;
  const mapped = /^(?:0{0,4}:){2,5}ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(raw);
  if (mapped?.[1]) return mapped[1];
  const unscoped = raw.split("%")[0] ?? raw;
  const halves = unscoped.split("::");
  if (halves.length > 2) return raw;
  const groups = (part: string | undefined) => (part ? part.split(":") : []);
  const head = groups(halves[0]);
  const tail = groups(halves[1]);
  // An embedded IPv4 tail fills the last two groups, which are never part of the /56 prefix.
  const fill = (list: string[]) => list.flatMap((g) => (g.includes(".") ? ["0", "0"] : [g]));
  const all =
    halves.length === 2
      ? [...fill(head), ...Array<string>(Math.max(0, 8 - fill(head).length - fill(tail).length)).fill("0"), ...fill(tail)]
      : fill(head);
  if (all.length !== 8 || !all.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return raw;
  const prefix = all.slice(0, 4).map((g) => Number.parseInt(g, 16));
  prefix[3] = (prefix[3] ?? 0) & 0xff00;
  return `${prefix.map((n) => n.toString(16)).join(":")}::/56`;
}

function unauthorized(code: "missing_token" | "invalid_token", message: string): HttpError {
  return new HttpError(401, code, message, { "www-authenticate": "Bearer" });
}

// Only a SHA-256 of the token is stored, so a KV leak does not leak usable tokens.
function tokenKey(hash: string): string {
  return `tok:${hash}`;
}

export async function handleInstall(ctx: Ctx): Promise<Response> {
  const { deps, env } = ctx;
  const now = deps.now();

  // cf-connecting-ip is set by Cloudflare's edge and cannot be supplied by the client; X-Forwarded-For
  // and similar headers are never trusted. IPs are only ever stored hashed, as short-lived counters.
  const ip = ctx.request.headers.get("cf-connecting-ip") ?? "unknown";
  const ipId = (await sha256Hex(`ip:${networkKey(ip)}`)).slice(0, 24);
  const hourBucket = Math.floor(now / 3_600_000);
  const count = await bumpCounter(ctx, `rl:install:${ipId}:${hourBucket}`, 7200);
  if (count > INSTALL_LIMIT_PER_HOUR) {
    throw new HttpError(429, "install_rate_limited", "Too many installs from this network; try again later", {
      "retry-after": String(secondsToNextHour(now)),
    });
  }

  const token = base64url(deps.randomBytes(TOKEN_BYTES));
  const hash = await sha256Hex(token);
  await env.PROXY_KV.put(tokenKey(hash), JSON.stringify({ createdAt: now }), {
    expirationTtl: TOKEN_TTL_SECONDS,
  });
  return jsonResponse(201, {
    token,
    expiresAt: new Date(now + TOKEN_TTL_SECONDS * 1000).toISOString(),
  });
}

// Returns the opaque token id used to key budgets. Throws 401 when the token is missing or unknown.
export async function authenticate(ctx: Ctx): Promise<string> {
  const header = ctx.request.headers.get("authorization");
  if (!header) {
    throw unauthorized("missing_token", "Authorization: Bearer <install token> is required");
  }
  const match = TOKEN_RE.exec(header.trim());
  if (!match || !match[1]) {
    // Malformed tokens never reach KV.
    throw unauthorized("invalid_token", "The install token is not valid");
  }
  const hash = await sha256Hex(match[1]);
  const now = ctx.deps.now();
  const cache = ctx.state.tokenCache;
  const cachedUntil = cache.get(hash);
  if (cachedUntil !== undefined && cachedUntil > now) return hash.slice(0, 32);

  const stored = await ctx.env.PROXY_KV.get(tokenKey(hash));
  if (stored === null) {
    cache.delete(hash);
    throw unauthorized("invalid_token", "The install token is not valid");
  }
  if (cache.size >= TOKEN_CACHE_MAX_ENTRIES) cache.clear();
  cache.set(hash, now + TOKEN_CACHE_TTL_MS);
  return hash.slice(0, 32);
}
