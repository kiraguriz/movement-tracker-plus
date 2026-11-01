# Cloudflare deployment — 2026-11-01

The project proxy is deployed and enabled at:

**https://movement-tracker-proxy.haitiandzhu.workers.dev**

Deployment version: `c36fe5a4-9186-4c4c-a893-fef051d5a34e`.

## Configuration

- `proxy/wrangler.jsonc` references the provisioned `PROXY_KV` namespace and SQLite `BudgetLedger`
  Durable Object. The binding was exercised by real authenticated requests.
- Cloudflare contains `MODEL_API_KEY` and `USDA_API_KEY` as Worker secrets. The user entered their values
  through Wrangler's hidden terminal prompts; no secret value was placed in chat, app configuration or git.
  Secret names were checked after deployment; both survived the subsequent deploy.
- Both app Debug and Release build configurations set the public `COACH_PROXY_URL`. A Release build's
  resulting `Info.plist` was checked to contain that URL. The URL is public configuration, not a credential.
- The Worker was first deployed with the kill switch on, then enabled after both secret names existed.
  The current `/v1/health` response is `{ "ok": true, "killSwitch": false }`.

## Verified live behavior

| Check | Result |
| --- | --- |
| Public health | HTTP 200; enabled |
| Install token | HTTP 201; 43-character token, not printed or committed |
| Muse non-streaming | HTTP 200; `muse-spark-1.3`, `completed`; 19 input / 71 output tokens |
| Muse streaming | HTTP 200; 12 SSE events; output text received and `response.completed` terminal event |
| USDA search | HTTP 200; `banana` returned 25 normalized results |
| App configuration | Release Simulator SDK build passed; embedded public URL matches the deployment |
| Simulator live Coach | One user prompt against real Muse, using synthetic seeded data; visible answer and local-session tool chip |
| Simulator live set review/debrief | Synthetic squat replay, no stub; Muse returned rep-specific advice and session metrics without a fallback indicator |
| Simulator live meal photo | Generated illustration, no stub; Muse estimate → USDA matching → confirm/save → Eat showed two items, 176 kcal total |

The install token used by the combined food/SSE check remained only in the checking process's memory.
These checks establish current proxy/API connectivity, not real-person movement accuracy or physical HealthKit
behavior. Simulator interaction details are in [ui-debug-report.md](ui-debug-report.md).

## Operation

From `proxy/`, redeploy with `npx wrangler deploy`. Secret values remain separate from the source.
To rotate one, use `npx wrangler secret put MODEL_API_KEY` or `npx wrangler secret put USDA_API_KEY` and
enter it in the hidden prompt. Use the same account as this deployment.

Current UTC-day caps: 500 accepted upstream reservations, 200 installations, 2,000 upstream attempts;
per-token/feature budgets and five installations per network/hour also apply. Refunds do not restore the
hard attempt cap. The limits count requests, not exact dollar charges.

Pause with `npx wrangler deploy --var KILL_SWITCH:1`; restore the committed configuration with
`npx wrangler deploy`. `tools/muse-smoke.sh` makes one real model request and can verify connectivity
after configuration changes. API keys are managed through the [Cloudflare secrets workflow](https://developers.cloudflare.com/workers/configuration/secrets/).
