import { refundBudget, reserveBudget } from "./budget.ts";
import { HttpError, badRequest, bytesToHex, isObject, readBodyCapped } from "./http.ts";
import { fetchUpstream, isRefundable, museBaseUrl, upstreamFailure } from "./upstream.ts";
import type { Ctx } from "./types.ts";

// 60 s of 16 kHz mono 16-bit WAV is 1,920,044 bytes; 2 MiB leaves room for multipart framing.
export const VOICE_MAX_BODY_BYTES = 2 * 1024 * 1024;
export const VOICE_DAILY_REQUESTS = 100;
export const VOICE_MODEL = "muse-voice-transcribe-1.0";

const MODES = new Set(["PUSH_TO_TALK", "ENDPOINTING"]);
const MAX_LANGUAGES = 5;
const MAX_KEYWORDS = 50;

function stringList(value: unknown, field: string, maxItems: number, maxLength: number): string[] {
  if (
    !Array.isArray(value) ||
    value.length > maxItems ||
    value.some((item) => typeof item !== "string" || item.length === 0 || item.length > maxLength)
  ) {
    throw badRequest("invalid_field", `${field} must be an array of at most ${maxItems} short strings`);
  }
  return value as string[];
}

// Only these settings reach upstream; model and encoding are fixed by the proxy.
function sanitizeTranscribeSettings(raw: unknown): Record<string, unknown> {
  const settings: Record<string, unknown> = {
    model: VOICE_MODEL,
    audioEncoding: "WAV",
    mode: "PUSH_TO_TALK",
  };
  if (raw === undefined) return settings;
  if (!isObject(raw)) throw badRequest("invalid_field", "The request part must be a JSON object");
  if (raw.mode !== undefined) {
    if (typeof raw.mode !== "string" || !MODES.has(raw.mode)) {
      throw badRequest("invalid_field", "mode must be PUSH_TO_TALK or ENDPOINTING");
    }
    settings.mode = raw.mode;
  }
  if (raw.languageBias !== undefined) {
    settings.languageBias = stringList(raw.languageBias, "languageBias", MAX_LANGUAGES, 32);
  }
  if (raw.keywords !== undefined) {
    settings.keywords = stringList(raw.keywords, "keywords", MAX_KEYWORDS, 64);
  }
  return settings;
}

function looksLikeWav(bytes: Uint8Array): boolean {
  if (bytes.byteLength < 44) return false;
  const tag = (start: number) => String.fromCharCode(...bytes.subarray(start, start + 4));
  return tag(0) === "RIFF" && tag(8) === "WAVE";
}

// Rebuilt by hand so the parts match Meta's documented request exactly: `request` (application/json,
// no filename) and `audio` (audio/wav).
function buildMultipart(boundary: string, settingsJson: string, audio: Uint8Array): Uint8Array<ArrayBuffer> {
  const encoder = new TextEncoder();
  const head = encoder.encode(
    `--${boundary}\r\nContent-Disposition: form-data; name="request"\r\nContent-Type: application/json\r\n\r\n` +
      `${settingsJson}\r\n` +
      `--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n`,
  );
  const tail = encoder.encode(`\r\n--${boundary}--\r\n`);
  const out = new Uint8Array(head.byteLength + audio.byteLength + tail.byteLength);
  out.set(head, 0);
  out.set(audio, head.byteLength);
  out.set(tail, head.byteLength + audio.byteLength);
  return out;
}

export async function handleVoice(ctx: Ctx): Promise<Response> {
  const key = ctx.env.MODEL_API_KEY;
  if (!key) throw new HttpError(500, "server_misconfigured", "The proxy is missing its model credentials");

  const contentType = ctx.request.headers.get("content-type") ?? "";
  if (!/^multipart\/form-data\s*;\s*boundary=/i.test(contentType)) {
    throw badRequest("invalid_content_type", "Send multipart/form-data with `request` and `audio` parts");
  }

  const bytes = await readBodyCapped(ctx.request, VOICE_MAX_BODY_BYTES);

  let form: FormData;
  try {
    form = await new Response(bytes, { headers: { "content-type": contentType } }).formData();
  } catch {
    throw badRequest("invalid_multipart", "The multipart body could not be parsed");
  }

  const audioPart = form.get("audio");
  if (audioPart === null || typeof audioPart === "string") {
    throw badRequest("invalid_multipart", "An `audio` file part is required");
  }
  const audio = new Uint8Array(await audioPart.arrayBuffer());
  if (!looksLikeWav(audio)) {
    throw badRequest("invalid_audio", "The audio part must be a WAV file (16 kHz mono 16-bit PCM, up to 60 s)");
  }

  let rawSettings: unknown;
  const requestPart = form.get("request");
  if (requestPart !== null) {
    const text = typeof requestPart === "string" ? requestPart : await requestPart.text();
    try {
      rawSettings = JSON.parse(text);
    } catch {
      throw badRequest("invalid_json", "The request part is not valid JSON");
    }
  }
  const settings = sanitizeTranscribeSettings(rawSettings);

  const reservation = await reserveBudget(ctx, "voice", VOICE_DAILY_REQUESTS);

  const boundary = `mtproxy${bytesToHex(ctx.deps.randomBytes(12))}`;
  let upstream: Response;
  try {
    upstream = await fetchUpstream(ctx, `${museBaseUrl(ctx)}/asr/transcribe`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${key}`,
        "content-type": `multipart/form-data; boundary=${boundary}`,
        accept: "application/json",
      },
      body: buildMultipart(boundary, JSON.stringify(settings), audio),
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

  return new Response(upstream.body, {
    status: 200,
    headers: {
      "content-type": upstream.headers.get("content-type") ?? "application/json",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}
