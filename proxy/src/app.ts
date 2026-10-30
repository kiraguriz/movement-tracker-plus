import { authenticate, handleInstall } from "./auth.ts";
import { handleCoach } from "./coach.ts";
import { handleFood } from "./food.ts";
import { HttpError, errorResponse, jsonResponse } from "./http.ts";
import { handleVoice } from "./voice.ts";
import type { CacheLike, Ctx, Deps, Env, ExecCtx, State } from "./types.ts";

interface Route {
  name: string;
  method: string;
  path: string;
  // Every route except install and health needs a valid install token.
  auth: boolean;
  handler: (ctx: Ctx) => Promise<Response>;
}

// Fail closed on every common spelling: an operator pausing the service in a hurry may type true or on.
export function isPaused(env: Env): boolean {
  return /^(1|true|yes|on)$/i.test(env.KILL_SWITCH?.trim() ?? "");
}

async function handleHealth(ctx: Ctx): Promise<Response> {
  return jsonResponse(200, { ok: true, killSwitch: isPaused(ctx.env) });
}

const ROUTES: Route[] = [
  { name: "health", method: "GET", path: "/v1/health", auth: false, handler: handleHealth },
  { name: "install", method: "POST", path: "/v1/install", auth: false, handler: handleInstall },
  { name: "coach", method: "POST", path: "/v1/coach/responses", auth: true, handler: handleCoach },
  { name: "voice", method: "POST", path: "/v1/voice/transcribe", auth: true, handler: handleVoice },
  { name: "food", method: "GET", path: "/v1/food/search", auth: true, handler: handleFood },
];

async function dispatch(ctx: Ctx, routeName: { value: string }): Promise<Response> {
  const sameMethod = ROUTES.find((r) => r.path === ctx.url.pathname && r.method === ctx.request.method);
  if (sameMethod) routeName.value = sameMethod.name;

  // Health always answers, so the app can tell "paused" from "offline".
  if (sameMethod?.name === "health") return sameMethod.handler(ctx);

  if (isPaused(ctx.env)) {
    throw new HttpError(503, "service_paused", "The coach service is paused", { "retry-after": "300" });
  }

  if (!sameMethod) {
    const allowed = ROUTES.filter((r) => r.path === ctx.url.pathname).map((r) => r.method);
    if (allowed.length === 0) throw new HttpError(404, "not_found", "Unknown route");
    throw new HttpError(405, "method_not_allowed", "Method not allowed for this route", {
      allow: allowed.join(", "),
    });
  }

  if (sameMethod.auth) ctx.tokenId = await authenticate(ctx);
  return sameMethod.handler(ctx);
}

export function createApp(deps: Deps) {
  // Positive token lookups live here, per isolate (and per app instance in tests).
  const state: State = { tokenCache: new Map(), counts: new Map() };

  return {
    async fetch(request: Request, env: Env, exec: ExecCtx): Promise<Response> {
      const started = deps.now();
      const ctx: Ctx = {
        request,
        url: new URL(request.url),
        env,
        exec,
        deps,
        state,
        tokenId: "",
        meta: {},
      };
      const route = { value: "unknown" };
      let response: Response;
      try {
        response = await dispatch(ctx, route);
      } catch (error) {
        response =
          error instanceof HttpError ? error.toResponse() : errorResponse(500, "internal", "Internal error");
      }
      // Route, status, latency and feature only: never bodies, tokens, keys or query strings.
      const entry: { route: string; status: number; ms: number; feature?: string } = {
        route: route.value,
        status: response.status,
        ms: deps.now() - started,
      };
      if (ctx.meta.feature) entry.feature = ctx.meta.feature;
      deps.log(entry);
      return response;
    },
  };
}

export function defaultDeps(): Deps {
  return {
    fetch: (input, init) => globalThis.fetch(input, init),
    now: () => Date.now(),
    randomBytes: (length) => crypto.getRandomValues(new Uint8Array(length)),
    getCache: () => {
      const caches = (globalThis as unknown as { caches?: { default?: CacheLike } }).caches;
      return caches?.default ?? null;
    },
    log: (entry) => console.log(JSON.stringify(entry)),
  };
}
