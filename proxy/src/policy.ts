import { HttpError, badRequest, isObject } from "./http.ts";

export const FEATURES = ["set_review", "debrief", "chat", "meal_photo", "spec_author", "goal_plan"] as const;
export type Feature = (typeof FEATURES)[number];

export function isFeature(value: string): value is Feature {
  return (FEATURES as readonly string[]).includes(value);
}

export const ALLOWED_MODELS: readonly string[] = ["muse-spark-1.3", "muse-spark-1.2"];
export const DEFAULT_MODEL = "muse-spark-1.3";

// Below roughly this many output tokens, reasoning can consume the whole budget and leave the answer
// empty (reasoning tokens share max_output_tokens), so smaller requests are raised to it.
export const MIN_OUTPUT_TOKENS = 4000;

const KIB = 1024;
const MIB = 1024 * KIB;

export interface Policy {
  efforts: readonly string[];
  defaultEffort: string;
  defaultMaxOutputTokens: number;
  maxOutputTokens: number;
  maxBodyBytes: number;
  // Body bytes other than inline image data. Images are bounded by maxBodyBytes and maxImages; this
  // stops a hostile client from filling the whole body cap with text, which is billed per token.
  maxTextBytes: number;
  maxImages: number;
  allowStream: boolean;
  allowTools: boolean;
  // Requests per install token per UTC day.
  dailyRequests: number;
}

// `xhigh` and `max` are not allowed for any feature: they multiply output cost with no coaching benefit.
// Body caps and daily request counts bound the worst case per install token.
export const POLICIES: Record<Feature, Policy> = {
  set_review: {
    efforts: ["minimal", "low", "medium"],
    defaultEffort: "low",
    defaultMaxOutputTokens: 4000,
    maxOutputTokens: 6000,
    maxBodyBytes: 2 * MIB,
    maxTextBytes: 128 * KIB,
    maxImages: 6,
    allowStream: true,
    allowTools: false,
    dailyRequests: 120,
  },
  debrief: {
    efforts: ["low", "medium", "high"],
    defaultEffort: "medium",
    defaultMaxOutputTokens: 6000,
    maxOutputTokens: 8000,
    maxBodyBytes: 256 * KIB,
    maxTextBytes: 256 * KIB,
    maxImages: 0,
    allowStream: true,
    allowTools: false,
    dailyRequests: 20,
  },
  chat: {
    efforts: ["low", "medium", "high"],
    defaultEffort: "medium",
    defaultMaxOutputTokens: 6000,
    maxOutputTokens: 8000,
    maxBodyBytes: 256 * KIB,
    maxTextBytes: 256 * KIB,
    maxImages: 0,
    allowStream: true,
    allowTools: true,
    dailyRequests: 100,
  },
  meal_photo: {
    efforts: ["minimal", "low", "medium"],
    defaultEffort: "low",
    defaultMaxOutputTokens: 4000,
    maxOutputTokens: 6000,
    // A 1-2 MB JPEG becomes 1.4-2.7 MB as a base64 data URL.
    maxBodyBytes: 4 * MIB,
    maxTextBytes: 64 * KIB,
    maxImages: 2,
    allowStream: false,
    allowTools: false,
    dailyRequests: 40,
  },
  spec_author: {
    efforts: ["low", "medium", "high"],
    defaultEffort: "medium",
    defaultMaxOutputTokens: 8000,
    maxOutputTokens: 12000,
    maxBodyBytes: 3 * MIB,
    maxTextBytes: 128 * KIB,
    maxImages: 8,
    // Meta's non-streaming requests have a server-side time limit (HTTP 504); streaming is exempt, and
    // this is the feature with the longest reasoning.
    allowStream: true,
    allowTools: false,
    dailyRequests: 20,
  },
  // The first calorie and macro plan, chosen inside ranges the phone computed. Numbers only, no images.
  goal_plan: {
    efforts: ["minimal", "low", "medium"],
    defaultEffort: "low",
    defaultMaxOutputTokens: 4000,
    maxOutputTokens: 6000,
    maxBodyBytes: 32 * KIB,
    maxTextBytes: 32 * KIB,
    maxImages: 0,
    allowStream: true,
    allowTools: false,
    dailyRequests: 10,
  },
};

// Top-level request fields we accept. Anything else is rejected, never forwarded: no previous_response_id,
// background, conversation, include, metadata, user, service_tier, web search, files, and so on.
const ALLOWED_FIELDS = new Set([
  "model",
  "input",
  "instructions",
  "reasoning",
  "max_output_tokens",
  "text",
  "tools",
  "tool_choice",
  "parallel_tool_calls",
  "stream",
  "store",
]);

const ALLOWED_ITEM_TYPES = new Set(["message", "function_call", "function_call_output", "reasoning"]);
// Text-only parts, plus input_image (checked below). input_file, input_video and input_audio can point at
// remote URLs or carry up to 70 MB, so they never pass. reasoning_text and summary_text appear in
// reasoning items the app replays.
const ALLOWED_PART_TYPES = new Set(["input_text", "input_image", "output_text", "refusal", "reasoning_text", "summary_text"]);
// Item fields that hold content parts: message.content and function_call_output.output (a string or a
// list of parts, per Meta's schema). Both go through the same checks.
const PART_FIELDS = ["content", "output"] as const;
const ALLOWED_TEXT_FORMATS = new Set(["text", "json_schema", "json_object"]);
const MAX_INPUT_ITEMS = 500;
const MAX_TOOLS = 16;

export interface SanitizedRequest {
  payload: Record<string, unknown>;
  stream: boolean;
}

function short(value: unknown): string {
  return String(value).replace(/[^\w.\- ]/g, "?").slice(0, 40);
}

interface InputStats {
  images: number;
  // Characters of inline image data; bytes for base64 data URLs.
  imageChars: number;
}

function validateParts(parts: unknown[], stats: InputStats): void {
  for (const part of parts) {
    if (!isObject(part) || typeof part.type !== "string" || !ALLOWED_PART_TYPES.has(part.type)) {
      throw badRequest(
        "unsupported_input_item",
        `content part type '${short(isObject(part) ? part.type : part)}' is not allowed`,
      );
    }
    if (part.type !== "input_image") continue;
    stats.images += 1;
    // Inline data URLs only: no remote URLs for the model host to fetch, no file ids.
    if (typeof part.image_url !== "string" || !part.image_url.startsWith("data:image/")) {
      throw badRequest("invalid_image_url", "input_image.image_url must be a data:image/... URL");
    }
    if (part.file_id !== undefined) throw badRequest("invalid_image_url", "input_image.file_id is not allowed");
    stats.imageChars += part.image_url.length;
  }
}

function validateInput(input: unknown, policy: Policy): InputStats {
  const stats: InputStats = { images: 0, imageChars: 0 };
  if (typeof input === "string") return stats;
  if (!Array.isArray(input) || input.length === 0 || input.length > MAX_INPUT_ITEMS) {
    throw badRequest("invalid_field", `input must be a string or a non-empty array of at most ${MAX_INPUT_ITEMS} items`);
  }
  for (const item of input) {
    if (!isObject(item)) throw badRequest("invalid_field", "input items must be objects");
    if (item.type !== undefined && (typeof item.type !== "string" || !ALLOWED_ITEM_TYPES.has(item.type))) {
      throw badRequest("unsupported_input_item", `input item type '${short(item.type)}' is not allowed`);
    }
    for (const field of PART_FIELDS) {
      const value = item[field];
      if (value === undefined || typeof value === "string") continue;
      if (!Array.isArray(value)) throw badRequest("invalid_field", `input item ${field} must be a string or an array`);
      validateParts(value, stats);
    }
  }
  if (stats.images > policy.maxImages) {
    throw badRequest(
      policy.maxImages === 0 ? "images_not_allowed" : "too_many_images",
      policy.maxImages === 0
        ? "This feature does not accept images"
        : `This feature accepts at most ${policy.maxImages} images`,
    );
  }
  return stats;
}

function sanitizeTools(tools: unknown, policy: Policy): unknown[] {
  if (!policy.allowTools) throw badRequest("tools_not_allowed", "This feature does not accept tools");
  if (!Array.isArray(tools) || tools.length === 0 || tools.length > MAX_TOOLS) {
    throw badRequest("invalid_field", `tools must be a non-empty array of at most ${MAX_TOOLS} function tools`);
  }
  return tools.map((tool) => {
    if (!isObject(tool) || tool.type !== "function" || typeof tool.name !== "string") {
      throw badRequest("unsupported_tool", "Only function tools are allowed");
    }
    const clean: Record<string, unknown> = { type: "function", name: tool.name };
    if (typeof tool.description === "string") clean.description = tool.description;
    if (isObject(tool.parameters)) clean.parameters = tool.parameters;
    if (typeof tool.strict === "boolean") clean.strict = tool.strict;
    return clean;
  });
}

// Validates a client request against the feature policy and rebuilds the upstream body from scratch.
export function sanitizeCoachRequest(body: unknown, policy: Policy, bodyBytes: number = 0): SanitizedRequest {
  if (!isObject(body)) throw badRequest("invalid_json", "The request body must be a JSON object");

  const unknown = Object.keys(body).filter((key) => !ALLOWED_FIELDS.has(key));
  if (unknown.length > 0) {
    throw badRequest("unsupported_field", `Unsupported field(s): ${unknown.slice(0, 10).map(short).join(", ")}`);
  }

  if (body.input === undefined) throw badRequest("invalid_field", "input is required");
  const stats = validateInput(body.input, policy);
  if (bodyBytes - stats.imageChars > policy.maxTextBytes) {
    throw new HttpError(
      413,
      "payload_too_large",
      `Request text (everything except inline images) exceeds the ${policy.maxTextBytes}-byte limit for this feature`,
    );
  }

  let model = DEFAULT_MODEL;
  if (body.model !== undefined) {
    if (typeof body.model !== "string" || !ALLOWED_MODELS.includes(body.model)) {
      throw badRequest("model_not_allowed", `model must be one of: ${ALLOWED_MODELS.join(", ")}`);
    }
    model = body.model;
  }

  let effort = policy.defaultEffort;
  if (body.reasoning !== undefined) {
    if (!isObject(body.reasoning)) throw badRequest("invalid_field", "reasoning must be an object");
    const extra = Object.keys(body.reasoning).filter((key) => key !== "effort");
    if (extra.length > 0) throw badRequest("unsupported_field", `Unsupported field(s): reasoning.${extra.map(short).join(", reasoning.")}`);
    if (body.reasoning.effort !== undefined) {
      const requested = body.reasoning.effort;
      if (typeof requested !== "string" || !policy.efforts.includes(requested)) {
        throw badRequest("effort_not_allowed", `reasoning.effort must be one of: ${policy.efforts.join(", ")}`);
      }
      effort = requested;
    }
  }

  let maxOutputTokens = policy.defaultMaxOutputTokens;
  if (body.max_output_tokens !== undefined) {
    const requested = body.max_output_tokens;
    if (typeof requested !== "number" || !Number.isInteger(requested)) {
      throw badRequest("invalid_field", "max_output_tokens must be an integer");
    }
    maxOutputTokens = Math.min(policy.maxOutputTokens, Math.max(MIN_OUTPUT_TOKENS, requested));
  }

  let stream = false;
  if (body.stream !== undefined) {
    if (typeof body.stream !== "boolean") throw badRequest("invalid_field", "stream must be a boolean");
    stream = body.stream;
    if (stream && !policy.allowStream) {
      throw badRequest("stream_not_allowed", "This feature does not support streaming");
    }
  }

  // Server-side storage is always off: nothing the user sends is retained, and there is no
  // previous_response_id to chain. Clients send the full conversation each time.
  const payload: Record<string, unknown> = {
    model,
    input: body.input,
    reasoning: { effort },
    max_output_tokens: maxOutputTokens,
    store: false,
  };
  if (stream) payload.stream = true;

  if (body.instructions !== undefined) {
    if (typeof body.instructions !== "string") throw badRequest("invalid_field", "instructions must be a string");
    payload.instructions = body.instructions;
  }

  if (body.text !== undefined) {
    if (!isObject(body.text)) throw badRequest("invalid_field", "text must be an object");
    const extra = Object.keys(body.text).filter((key) => key !== "format");
    if (extra.length > 0) throw badRequest("unsupported_field", `Unsupported field(s): text.${extra.map(short).join(", text.")}`);
    if (body.text.format !== undefined) {
      const format = body.text.format;
      if (!isObject(format) || typeof format.type !== "string" || !ALLOWED_TEXT_FORMATS.has(format.type)) {
        throw badRequest("invalid_field", "text.format.type must be text, json_schema or json_object");
      }
      payload.text = { format };
    }
  }

  if (body.tools !== undefined) payload.tools = sanitizeTools(body.tools, policy);

  if (body.tool_choice !== undefined) {
    if (body.tool_choice !== "auto") throw badRequest("invalid_field", "tool_choice must be \"auto\"");
    payload.tool_choice = "auto";
  }
  if (body.parallel_tool_calls !== undefined) {
    if (typeof body.parallel_tool_calls !== "boolean") {
      throw badRequest("invalid_field", "parallel_tool_calls must be a boolean");
    }
    payload.parallel_tool_calls = body.parallel_tool_calls;
  }

  return { payload, stream };
}
