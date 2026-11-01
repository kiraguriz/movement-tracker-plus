# Movement Tracker+ proxy

A Cloudflare Worker (TypeScript, no runtime dependencies) that holds the Meta Model API key and the USDA
FoodData Central key, so no key ever ships in the iOS app. The app gets a random install token from
`POST /v1/install` and sends it as a Bearer token on every other call.

Plan of record: `docs/rebuild-brief.md` §7.1–§7.4. Where Meta's current docs differ from the brief, this
proxy follows the docs (see "Contract notes").

## Routes

All errors are JSON: `{ "error": { "code": "...", "message": "..." } }`.

| Route | Auth | What it does |
| --- | --- | --- |
| `GET /v1/health` | none | `{ "ok": true, "killSwitch": false }`. Always answers, even when paused. |
| `POST /v1/install` | none | Returns `201 { token, expiresAt }`. Token is 256 random bits, base64url (43 chars). At most 5 per hour per network: per IPv4 address, per IPv6 /64, keyed on Cloudflare's `cf-connecting-ip` (forwarding headers are ignored). |
| `POST /v1/coach/responses` | Bearer | Forwards to `{MUSE_BASE_URL}/responses` with the server key. Needs header `X-Coach-Feature`. |
| `POST /v1/voice/transcribe` | Bearer | Multipart (`request` + `audio`) to `{MUSE_BASE_URL}/asr/transcribe`. Whole body at most 2 MiB. |
| `GET /v1/food/search?q=&page=` | Bearer | USDA search, normalized, edge-cached for a day. At most 300 USDA calls per token per UTC day (cache hits are free). |

`KILL_SWITCH` set to `1`, `true`, `yes` or `on` (any case, surrounding spaces ignored) answers
`503 service_paused` (with `Retry-After: 300`) on everything except `GET /v1/health`. Any other value
(including unset, `0`, `false`) leaves the service running.

### Coach policy (`X-Coach-Feature`)

Only `muse-spark-1.3` (default) and `muse-spark-1.2` are accepted. `reasoning.effort` outside the feature's
list is a 400 (`effort_not_allowed`), never silently changed. `xhigh`, `max` and `none` are never allowed.
`max_output_tokens` is clamped into 4000 to the feature cap, because below about 4000 reasoning can use the
whole budget and leave the answer empty.

| Feature | Efforts (default first) | max_output_tokens (default / cap) | Body cap | Text cap | Images | Stream | Tools | Requests per token per UTC day |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `set_review` | low, minimal, medium | 4000 / 6000 | 2 MiB | 128 KiB | 6 | yes | no | 120 |
| `debrief` | medium, low, high | 6000 / 8000 | 256 KiB | 256 KiB | 0 | yes | no | 20 |
| `chat` | medium, low, high | 6000 / 8000 | 256 KiB | 256 KiB | 0 | yes | function tools | 100 |
| `meal_photo` | low, minimal, medium | 4000 / 6000 | 4 MiB | 64 KiB | 2 | no | no | 40 |
| `spec_author` | medium, low, high | 8000 / 12000 | 3 MiB | 128 KiB | 8 | yes | no | 20 |

The text cap is the body minus inline image data. Text is billed per token, so a hostile client could
otherwise fill a multi-MiB image allowance with text (about 0.6 USD per request at 2 MiB). Over it is
`413 payload_too_large`.

Voice has its own budget of 100 requests per token per day, and food search 300 (USDA calls only). The
budget unit is requests, counted before the upstream call. The request is given back when the failure is
ours or upstream's (timeouts, unreachable, 401/402/403/404/429/5xx) but not when upstream rejects it as
invalid (400, 413, 422): refunding those would turn a loop of bad requests into free calls that eat Meta's
shared team rate limit. Exhaustion is `429 daily_budget_exceeded` with `Retry-After` set to the seconds
until 00:00 UTC.

The policy table lives in `src/policy.ts`; `test/coach.test.ts` pins every number, so a change is deliberate.

### Request rules for the app

- The upstream body is rebuilt from an allowlist: `model`, `input`, `instructions`, `reasoning.effort`,
  `max_output_tokens`, `text.format`, `tools`, `tool_choice` (`"auto"` only), `parallel_tool_calls`,
  `stream`, `store`. Any other top-level field is `400 unsupported_field` (for example
  `previous_response_id`, `background`, `metadata`, `include`, `user`).
- `store` is always forced to `false`: nothing is retained upstream and there is no `previous_response_id`.
  Send the whole conversation each time (including `function_call` and `function_call_output` items).
- `input` items may be `message`, `function_call`, `function_call_output` or `reasoning`; content parts may
  be `input_text`, `input_image`, `output_text`, `refusal`, `reasoning_text` or `summary_text`. The same
  checks run on `content` and on `function_call_output.output` (which Meta allows to be a list of parts).
  Images, wherever they appear, must be `data:image/...` URLs and count toward the feature's image limit:
  no remote URLs, file ids, files, audio or video.
- Tools: `type: "function"` only, only for `chat`. Built-in tools such as `web_search` are rejected.
- Streaming: send `"stream": true`. The response is Meta's SSE passed through unbuffered: `data:` lines whose
  JSON has a `type` (for example `response.output_text.delta`), ending with `data: [DONE]`. Stream failures
  arrive inside the 200 as `response.failed` or `error` events, not as HTTP statuses.
- Voice: WAV, mono, 16-bit, **16 kHz**, at most 60 s (24 kHz would exceed the 2 MiB cap). The optional
  `request` part may set `mode` (`PUSH_TO_TALK` or `ENDPOINTING`), `languageBias`, `keywords`; model and
  encoding are fixed by the proxy.
- Food search: `q` is 2 to 100 characters, `page` is 1 to 50 (25 results per page). Each result is
  `{ fdcId, name, brand?, dataType, per100g: { kcal, protein, carbs, fat }, servings?: [{ label, grams }] }`
  inside `{ query, page, totalPages, totalHits, results }`. A nutrient USDA does not report is `null`, never
  `0`. kcal falls back to Atwater kcal, then to kJ / 4.184. Servings come from gram-based branded serving
  sizes and from household measures (only Survey foods carry them in search results; Foundation and SR
  Legacy results have none); millilitre sizes are skipped. USDA reports every data type per 100 g except
  branded liquids, whose serving unit is `ml` or `MLT` and whose values are per 100 ml. Those items carry
  `basis: "ml"` (the field is absent otherwise), so the app can show "per 100 ml" instead of treating
  millilitres as grams. Repeated `q` or `page` parameters use the first value. The echoed `query` is the
  caller's own normalized `q`, also on a cache hit.

### Errors the app must handle

| Status | Code | Meaning |
| --- | --- | --- |
| 401 | `missing_token`, `invalid_token` | Call `POST /v1/install` again and replace the stored token. Tokens last 120 days. |
| 400 | `invalid_feature`, `unsupported_field`, `model_not_allowed`, `effort_not_allowed`, `stream_not_allowed`, ... | Client bug; fix the request. |
| 413 | `payload_too_large` | Over the feature (or voice) cap. |
| 429 | `daily_budget_exceeded`, `global_budget_exceeded`, `global_attempt_limit`, `global_install_limit`, `install_rate_limited`, `upstream_rate_limited` | Wait for `Retry-After` seconds. |
| 503 | `budget_unavailable` | Durable ledger is missing/unreachable; no upstream call was made. |
| 502 / 503 / 504 | `upstream_error`, `upstream_unavailable`, `upstream_timeout`, `upstream_unauthorized`, `service_paused` | Retry later; 503 carries `Retry-After`. |

Redirects from upstream are never followed (the server key must not be replayed to another origin), and
no upstream response header (`set-cookie`, `server`, request ids, rate-limit headers) reaches the app.

Upstream failures are mapped, never forwarded verbatim: upstream 429 and 503 keep their `Retry-After`
(defaults: 5 s for Meta 429, 30 s for 503, 3600 s for USDA 429), 504 stays 504, other 5xx become 502, an
upstream 400 surfaces its sanitized message as `upstream_bad_request`, and 401/402/403 become a generic
`upstream_unauthorized` with no upstream text.

## Privacy and logging

The only log line per request is `{ route, status, ms, feature? }`. Request and response bodies, install
tokens, keys, IPs and query strings are never logged. KV holds SHA-256 hashes of install tokens. The
Durable Object holds counters keyed by truncated token/network hashes and random reservation IDs.
Meta's `*-contributor` models (data used to improve Meta products) are
not in the allowlist.

## Deploy (your steps)

Run from `proxy/`. You need a Cloudflare account; no key is ever committed.

```sh
npm ci
npx wrangler login
npx wrangler kv namespace create movement-tracker-proxy
# Paste the printed id into wrangler.jsonc, kv_namespaces[0].id (replace REPLACE_WITH_KV_NAMESPACE_ID).
npx wrangler secret put MODEL_API_KEY     # the Meta Model API key (starts with LLM_)
npx wrangler secret put USDA_API_KEY      # free key from https://api.data.gov/signup/
npx wrangler deploy
```

Deployment also provisions the `BudgetLedger` SQLite Durable Object using the migration in
`wrangler.jsonc`. Its `REQUIRE_DURABLE_BUDGETS=1` setting rejects requests before an upstream call if
the binding is missing or unavailable. Do not disable it on a public deployment.

Configure the app with the public URL only, for both Debug and Release:

```sh
xcodebuild -project MovementTracker.xcodeproj -scheme MovementTracker \
  -destination 'generic/platform=iOS' COACH_PROXY_URL=https://your-worker.workers.dev build
```

`Config/Info.plist` expands this setting into `CoachProxyURL`. The app rejects non-HTTPS URLs,
embedded credentials and query tokens. With no URL it uses on-device coach fallbacks and manual
nutrition entry. Debug's existing `-coachURL http://localhost:8787` override remains available.

If `secret put` asks to create the Worker first, answer yes. Then check it from the repo root:

```sh
PROXY_URL=https://movement-tracker-proxy.<your-subdomain>.workers.dev tools/muse-smoke.sh
```

Pause everything (the app can still read `/v1/health`) and resume:

```sh
npx wrangler deploy --var KILL_SWITCH:1
npx wrangler deploy            # back to "0" from wrangler.jsonc
```

## Local development

```sh
cd proxy
npm install
printf 'MODEL_API_KEY=...\nUSDA_API_KEY=...\n' > .dev.vars   # gitignored at the repo root
npx wrangler dev                                             # http://127.0.0.1:8787, local KV
PROXY_URL=http://127.0.0.1:8787 ../tools/muse-smoke.sh
```

`wrangler dev` uses a local KV simulation, so the placeholder namespace id is fine. To point at a fake
upstream: `npx wrangler dev --var MUSE_BASE_URL:http://127.0.0.1:8799/v1`.

## Dependency pin

`wrangler` is pinned to 4.151.0, the newest release at least 14 days old when this was set (2026-10-29),
and `package-lock.json` was generated with `npm install --before=2026-10-15` so every transitive package
is at least that old too. `compatibility_date` in `wrangler.jsonc` must stay at or below what the pinned
workerd supports (2026-10-19 for workerd 1.20261012.1), or `wrangler dev` refuses to start. `npm audit`
reports undici 7.29.1, pinned exactly by miniflare, in dev tooling only; the deployed Worker bundles no
npm code. The fix ships with wrangler 4.153 or later; move the pin once that is old enough.

## Tests and build

```sh
npm test            # node --test over test/*.test.ts (Node 24+ strips types; no TypeScript dependency)
npm run build       # wrangler deploy --dry-run --outdir dist (no login; dist/ is gitignored)
```

Tests use an in-memory KV with a fake clock, an in-memory cache and an injected `fetch`; nothing touches the
network. Source is erasable TypeScript with explicit `.ts` import extensions; `tsconfig.json` is for
editors only (`noEmit`).

## Durable limits and operational boundaries

- **Authoritative counters use one named SQLite Durable Object.** Each reservation atomically checks
  the feature/token budget and the global budget; all Worker isolates share it. Refunds are idempotent.
  Expired counter/receipt rows are pruned on subsequent traffic. KV is no longer written per paid call.
- **Global defaults per UTC day:** `GLOBAL_DAILY_REQUESTS=500` accepted upstream reservations,
  `GLOBAL_DAILY_INSTALLS=200` installations and `GLOBAL_DAILY_ATTEMPTS=2000` upstream attempts.
  Refundable upstream failures restore the first limit, but never the attempt limit. Limits can be lowered
  through Worker vars. They are request caps; actual provider charges still depend on token usage.
- **Installs remain anonymous.** Five per network/hour plus the global install cap bound token issuance;
  App Attest remains a later feature. The shared ledger is intentionally one coordinator for demo scale.
- **Local compatibility:** tests can omit the binding to exercise the old best-effort KV fallback. The
  deployed config requires the durable binding and never silently falls back.
- **Cache API:** Cloudflare documents working cache operations for Workers on custom domains; on
  `*.workers.dev` it is not confirmed. If it does not cache there, search still works but every query calls
  USDA (1,000 requests per hour per key; USDA blocks the key for an hour when exceeded).
- **Token revocation** (deleting `tok:<sha256>` from KV) takes up to 5 minutes to reach warm isolates.
- Provider/team quotas, paid-account usage and real latency require live credentials and deployment.
  Local tests and dry-run builds do not establish those results.

## Sources used (read 2026-10-29)

- Meta Model API: https://dev.meta.ai/docs/ (index), `/docs/api-reference/responses/create-response`,
  `/docs/api-reference/responses/schemas`, `/docs/protocols/responses`, `/docs/authentication`,
  `/docs/error-handling`, `/docs/pricing-rate-limits`, `/docs/models`, `/docs/reasoning`,
  `/docs/speech-to-text`, `/docs/api-reference/voice/transcribe`
- USDA FoodData Central: https://fdc.nal.usda.gov/api-guide (redirects to `/api-guide/`), the OpenAPI spec
  `https://fdc.nal.usda.gov/api-spec/fdc_api.json`, and live responses from
  `https://api.nal.usda.gov/fdc/v1/foods/search` (public `DEMO_KEY`, header `X-Api-Key` confirmed working)
- Cloudflare: https://developers.cloudflare.com/workers/runtime-apis/cache/ (Cache API),
  https://developers.cloudflare.com/kv/platform/limits/ and
  https://developers.cloudflare.com/workers/platform/limits/ (plan limits)

## Contract notes (docs vs brief)

- USDA's OpenAPI spec lists `number`, `name`, `amount` for search nutrients, but real responses carry
  `nutrientId`, `nutrientNumber`, `nutrientName`, `unitName`, `value`. The normalizer follows the real
  payload. Ids: protein 1003, fat 1004, carbohydrate 1005, energy kcal 1008 (kJ 1062; Atwater kcal 2047 and
  2048).
- Meta's `store` defaults to `true`; the proxy forces `false`.
- Streaming is documented as `data:` JSON lines with a `type` field and a final `data: [DONE]`; `event:`
  lines are not documented.
- Non-streaming requests have a server time limit on the whole response (504, no number documented);
  for streaming the limit applies only until the first event arrives. Hence streaming is allowed for all
  features except `meal_photo`. Meta's own error body is `{ error: { message, type, param, code } }`; this
  proxy always answers with its own `{ error: { code, message } }`.
- Mid-stream failures arrive as terminal events inside the 200: `response.failed` (response `status:
  "failed"` plus an `error` object) or a top-level `error` event. `response.incomplete` is the other
  non-success terminal event. The proxy forwards all of them untouched.
- Meta's `function_call_output.output` may be a list of `input_text`, `input_image` and `input_file`
  parts, and `input_image.image_url` / `input_file.file_url` accept remote URLs, so the proxy validates
  `output` exactly like message content.
- ASR `languageBias` takes language names (for example `"English"`, `"Mandarin Chinese"`; 25 supported).
  `mode` also has `DIARIZATION`, which the proxy does not allow. WAV may be 16 or 24 kHz mono 16-bit;
  the 2 MiB body cap makes 16 kHz the practical choice for 60 s.
- ASR `request` JSON uses `model`, `audioEncoding`, `mode`, `languageBias`, `keywords`. Its 429 means the
  concurrency (256) or hourly (16,000 sessions) limit, and carries no `x-ratelimit-*` headers.
