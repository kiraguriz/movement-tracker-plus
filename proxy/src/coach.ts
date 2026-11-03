import { refundBudget, reserveBudget } from "./budget.ts";
import { HttpError, badRequest, readBodyCapped } from "./http.ts";
import { POLICIES, isFeature, sanitizeCoachRequest } from "./policy.ts";
import { fetchUpstream, isRefundable, museBaseUrl, upstreamFailure } from "./upstream.ts";
import type { Ctx } from "./types.ts";

export async function handleCoach(ctx: Ctx): Promise<Response> {
  const key = ctx.env.MODEL_API_KEY;
  if (!key) throw new HttpError(500, "server_misconfigured", "The proxy is missing its model credentials");

  const featureHeader = ctx.request.headers.get("x-coach-feature")?.trim() ?? "";
  if (!isFeature(featureHeader)) {
    throw badRequest("invalid_feature", "X-Coach-Feature must be one of: set_review, debrief, chat, meal_photo, spec_author, goal_plan");
  }
  const feature = featureHeader;
  const policy = POLICIES[feature];
  ctx.meta.feature = feature;

  const bytes = await readBodyCapped(ctx.request, policy.maxBodyBytes);
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw badRequest("invalid_json", "The request body is not valid JSON");
  }
  const { payload, stream } = sanitizeCoachRequest(parsed, policy, bytes.byteLength);

  const reservation = await reserveBudget(ctx, feature, policy.dailyRequests);

  let upstream: Response;
  try {
    upstream = await fetchUpstream(ctx, `${museBaseUrl(ctx)}/responses`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${key}`,
        "content-type": "application/json",
        accept: stream ? "text/event-stream" : "application/json",
      },
      body: JSON.stringify(payload),
    });
  } catch (error) {
    await refundBudget(ctx, reservation);
    throw error;
  }

  if (!upstream.ok) {
    const failure = await upstreamFailure(ctx, upstream, { rateLimitFallbackSeconds: 5 });
    if (isRefundable(failure)) await refundBudget(ctx, reservation);
    throw failure;
  }

  // The body is handed through as a stream: SSE chunks reach the app as upstream emits them.
  const headers: Record<string, string> = {
    "content-type":
      upstream.headers.get("content-type") ?? (stream ? "text/event-stream; charset=utf-8" : "application/json"),
    "cache-control": "no-store, no-transform",
    "x-content-type-options": "nosniff",
  };
  if (stream) headers["x-accel-buffering"] = "no";
  return new Response(upstream.body, { status: 200, headers });
}
