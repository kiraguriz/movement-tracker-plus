import { HttpError } from "./http.ts";
import type { Ctx } from "./types.ts";

export const DEFAULT_MUSE_BASE_URL = "https://api.meta.ai/v1";

// Meta documents a server-side limit for non-streaming requests; give up a little after it.
const UPSTREAM_HEADER_TIMEOUT_MS = 110_000;

export function museBaseUrl(ctx: Ctx): string {
  const raw = ctx.env.MUSE_BASE_URL?.trim() || DEFAULT_MUSE_BASE_URL;
  return raw.replace(/\/+$/, "");
}

// Waits for upstream response headers only. The body (including an SSE stream) is never buffered here.
// Redirects are not followed so the server key can never be replayed to another origin.
export async function fetchUpstream(
  ctx: Ctx,
  url: string,
  init: RequestInit,
  timeoutMs: number = UPSTREAM_HEADER_TIMEOUT_MS,
): Promise<Response> {
  const controller = new AbortController();
  let timedOut = false;
  const onClientAbort = () => controller.abort();
  ctx.request.signal.addEventListener("abort", onClientAbort, { once: true });
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  try {
    return await ctx.deps.fetch(url, { ...init, redirect: "manual", signal: controller.signal });
  } catch {
    if (timedOut) throw new HttpError(504, "upstream_timeout", "The upstream service did not respond in time");
    throw new HttpError(502, "upstream_unreachable", "Could not reach the upstream service");
  } finally {
    clearTimeout(timer);
  }
}

export function parseRetryAfter(value: string | null, nowMs: number): number | null {
  if (value === null) return null;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed);
  const date = Date.parse(trimmed);
  if (Number.isNaN(date)) return null;
  return Math.max(0, Math.ceil((date - nowMs) / 1000));
}

function retryAfterHeader(res: Response, nowMs: number, fallback: number): Record<string, string> {
  const parsed = parseRetryAfter(res.headers.get("retry-after"), nowMs);
  const seconds = Math.min(3600, Math.max(1, parsed ?? fallback));
  return { "retry-after": String(seconds) };
}

async function upstreamMessage(res: Response): Promise<string | null> {
  try {
    const text = (await res.text()).slice(0, 4096);
    const parsed: unknown = JSON.parse(text);
    if (typeof parsed === "object" && parsed !== null && "error" in parsed) {
      const error = (parsed as { error: unknown }).error;
      if (typeof error === "object" && error !== null && "message" in error) {
        const message = (error as { message: unknown }).message;
        if (typeof message === "string" && message.length > 0) {
          return message.replace(/LLM_[A-Za-z0-9_]+/g, "[redacted]").slice(0, 300);
        }
      }
    }
  } catch {
    // Non-JSON or unreadable error bodies are summarized by status only.
  }
  return null;
}

// Whether the request should be given back to the user's budget. Upstream's 400, 413 and 422 mean the
// request itself was unacceptable: refunding those would turn a loop of invalid requests into free calls.
export function isRefundable(failure: HttpError): boolean {
  return failure.status !== 400 && failure.status !== 413;
}

export interface UpstreamFailureOptions {
  // Used when upstream sends 429 or 503 without Retry-After.
  rateLimitFallbackSeconds: number;
}

// Maps a non-2xx upstream response to our error envelope. Upstream bodies are never forwarded verbatim:
// only a 400's sanitized message is surfaced, and credential-class failures stay generic.
export async function upstreamFailure(
  ctx: Ctx,
  res: Response,
  options: UpstreamFailureOptions,
): Promise<HttpError> {
  const now = ctx.deps.now();
  const status = res.status;
  // Only a 400's body is read (below); release the connection for every other status.
  if (status !== 400 && status !== 422) void res.body?.cancel().catch(() => {});
  if (status === 429) {
    return new HttpError(
      429,
      "upstream_rate_limited",
      "The upstream service is rate limited; retry after the indicated delay",
      retryAfterHeader(res, now, options.rateLimitFallbackSeconds),
    );
  }
  if (status === 503) {
    return new HttpError(
      503,
      "upstream_unavailable",
      "The upstream service is temporarily unavailable",
      retryAfterHeader(res, now, 30),
    );
  }
  if (status === 504) {
    return new HttpError(504, "upstream_timeout", "The upstream service timed out; retry with a smaller request");
  }
  if (status === 400 || status === 422) {
    const message = await upstreamMessage(res);
    return new HttpError(400, "upstream_bad_request", message ?? "The upstream service rejected the request");
  }
  if (status === 413) {
    return new HttpError(413, "upstream_payload_too_large", "The upstream service rejected the request size");
  }
  if (status === 401 || status === 402 || status === 403) {
    return new HttpError(502, "upstream_unauthorized", "The proxy could not authenticate with the upstream service");
  }
  return new HttpError(502, "upstream_error", "The upstream service returned an error");
}
