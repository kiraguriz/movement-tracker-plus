import { refundBudget, reserveBudget } from "./budget.ts";
import { HttpError, badRequest, isObject } from "./http.ts";
import { fetchUpstream, isRefundable, upstreamFailure } from "./upstream.ts";
import type { Ctx } from "./types.ts";

export const USDA_SEARCH_URL = "https://api.nal.usda.gov/fdc/v1/foods/search";
export const FOOD_PAGE_SIZE = 25;
export const FOOD_MAX_PAGE = 50;
export const FOOD_QUERY_MIN = 2;
export const FOOD_QUERY_MAX = 100;
// Per install token and UTC day, counted only when USDA is actually called (cache hits are free). USDA
// blocks the shared key for an hour above 1,000 requests per hour, so one runaway client must not be
// able to take search away from everyone.
export const FOOD_DAILY_REQUESTS = 300;
const EDGE_CACHE_SECONDS = 86_400;
const KJ_PER_KCAL = 4.184;
const MAX_SERVINGS = 8;

export interface FoodItem {
  fdcId: number;
  name: string;
  brand?: string;
  dataType: string;
  // Present only when the per-100 values are really per 100 ml (USDA reports branded liquids by volume).
  basis?: "ml";
  per100g: { kcal: number | null; protein: number | null; carbs: number | null; fat: number | null };
  servings?: { label: string; grams: number }[];
}

export interface FoodSearchResult {
  query: string;
  page: number;
  totalPages: number;
  totalHits: number;
  results: FoodItem[];
}

// FoodData Central nutrient ids (nutrientNumber in parentheses). Search results report amounts per 100 g.
const PROTEIN = { ids: [1003], numbers: ["203"] };
const FAT = { ids: [1004], numbers: ["204"] };
const CARBS = { ids: [1005], numbers: ["205"] };
// Energy in order of preference: kcal, Atwater specific kcal, Atwater general kcal, then kJ.
const ENERGY_CANDIDATES = [
  { ids: [1008], numbers: ["208"] },
  { ids: [2048], numbers: ["958"] },
  { ids: [2047], numbers: ["957"] },
  { ids: [1062], numbers: ["268"] },
];

interface NutrientSpec {
  ids: number[];
  numbers: string[];
}

function finiteNonNegative(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}

function findNutrient(nutrients: Record<string, unknown>[], spec: NutrientSpec): Record<string, unknown> | null {
  for (const entry of nutrients) {
    const id = entry.nutrientId;
    const number = entry.nutrientNumber;
    if ((typeof id === "number" && spec.ids.includes(id)) || (typeof number === "string" && spec.numbers.includes(number))) {
      return entry;
    }
  }
  return null;
}

function unitOf(entry: Record<string, unknown>): string {
  return typeof entry.unitName === "string" ? entry.unitName.trim().toUpperCase() : "";
}

function gramsOf(nutrients: Record<string, unknown>[], spec: NutrientSpec): number | null {
  const entry = findNutrient(nutrients, spec);
  if (!entry) return null;
  const value = finiteNonNegative(entry.value);
  if (value === null) return null;
  const unit = unitOf(entry);
  if (unit === "MG") return value / 1000;
  if (unit === "UG") return value / 1_000_000;
  return value;
}

function kcalOf(nutrients: Record<string, unknown>[]): number | null {
  for (const spec of ENERGY_CANDIDATES) {
    const entry = findNutrient(nutrients, spec);
    if (!entry) continue;
    const value = finiteNonNegative(entry.value);
    if (value === null) continue;
    if (unitOf(entry) === "KJ") return Math.round((value / KJ_PER_KCAL) * 10) / 10;
    return value;
  }
  return null;
}

function isVolumeBased(food: Record<string, unknown>): boolean {
  const unit = typeof food.servingSizeUnit === "string" ? food.servingSizeUnit.trim().toLowerCase() : "";
  return unit === "ml" || unit === "mlt";
}

function servingsOf(food: Record<string, unknown>): { label: string; grams: number }[] {
  const servings: { label: string; grams: number }[] = [];

  // Branded foods describe one labelled serving. Only gram-based sizes are usable: millilitres would
  // need a density we do not know.
  const size = finiteNonNegative(food.servingSize);
  const unit = typeof food.servingSizeUnit === "string" ? food.servingSizeUnit.trim().toLowerCase() : "";
  if (size !== null && size > 0 && (unit === "g" || unit === "grm")) {
    const household = typeof food.householdServingFullText === "string" ? food.householdServingFullText.trim() : "";
    servings.push({ label: household || `${size} g`, grams: size });
  }

  // Foundation, SR Legacy and Survey foods list household measures with gram weights.
  if (Array.isArray(food.foodMeasures)) {
    const measures = food.foodMeasures
      .filter(isObject)
      .map((m) => ({
        label: typeof m.disseminationText === "string" ? m.disseminationText.trim() : "",
        grams: finiteNonNegative(m.gramWeight),
        rank: typeof m.rank === "number" ? m.rank : Number.MAX_SAFE_INTEGER,
      }))
      .filter((m) => m.label !== "" && m.grams !== null && m.grams > 0 && !/^quantity not specified$/i.test(m.label))
      .sort((a, b) => a.rank - b.rank);
    for (const m of measures) {
      if (servings.length >= MAX_SERVINGS) break;
      if (servings.some((s) => s.label === m.label)) continue;
      servings.push({ label: m.label, grams: m.grams as number });
    }
  }
  return servings;
}

export function normalizeFood(raw: unknown): FoodItem | null {
  if (!isObject(raw)) return null;
  const fdcId = raw.fdcId;
  const name = typeof raw.description === "string" ? raw.description.trim() : "";
  if (typeof fdcId !== "number" || !Number.isInteger(fdcId) || name === "") return null;

  const nutrients = Array.isArray(raw.foodNutrients) ? raw.foodNutrients.filter(isObject) : [];
  const item: FoodItem = {
    fdcId,
    name,
    dataType: typeof raw.dataType === "string" && raw.dataType !== "" ? raw.dataType : "Unknown",
    per100g: {
      kcal: kcalOf(nutrients),
      protein: gramsOf(nutrients, PROTEIN),
      carbs: gramsOf(nutrients, CARBS),
      fat: gramsOf(nutrients, FAT),
    },
  };
  const brand =
    (typeof raw.brandName === "string" && raw.brandName.trim()) ||
    (typeof raw.brandOwner === "string" && raw.brandOwner.trim()) ||
    "";
  if (brand) item.brand = brand;
  if (isVolumeBased(raw)) item.basis = "ml";
  const servings = servingsOf(raw);
  if (servings.length > 0) item.servings = servings;
  return item;
}

export function normalizeSearch(raw: unknown, query: string, page: number): FoodSearchResult {
  const body = isObject(raw) ? raw : {};
  const foods = Array.isArray(body.foods) ? body.foods : [];
  const results: FoodItem[] = [];
  for (const food of foods) {
    const item = normalizeFood(food);
    if (item) results.push(item);
  }
  return {
    query,
    page,
    totalPages: finiteNonNegative(body.totalPages) ?? 0,
    totalHits: finiteNonNegative(body.totalHits) ?? 0,
    results,
  };
}

function cleanQuery(raw: string | null): string {
  const q = (raw ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  if (q.length < FOOD_QUERY_MIN || q.length > FOOD_QUERY_MAX) {
    throw badRequest("invalid_query", `q must be ${FOOD_QUERY_MIN} to ${FOOD_QUERY_MAX} characters`);
  }
  return q;
}

function parsePage(raw: string | null): number {
  if (raw === null || raw === "") return 1;
  const page = /^\d{1,3}$/.test(raw) ? Number(raw) : NaN;
  if (!Number.isInteger(page) || page < 1 || page > FOOD_MAX_PAGE) {
    throw badRequest("invalid_page", `page must be an integer from 1 to ${FOOD_MAX_PAGE}`);
  }
  return page;
}

// Cache entries are shared by every spelling of a query ("Cheddar  CHEESE", "cheddar cheese"), so the
// stored `query` is whatever the first caller typed. Answer with this caller's own normalized query.
function echoQuery(stored: string, query: string): string {
  try {
    const parsed: unknown = JSON.parse(stored);
    if (isObject(parsed)) return JSON.stringify({ ...parsed, query });
  } catch {
    // Fall through to the stored body.
  }
  return stored;
}

function clientResponse(body: string, cacheStatus: "HIT" | "MISS"): Response {
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "private, max-age=3600",
      "x-content-type-options": "nosniff",
      "x-cache": cacheStatus,
    },
  });
}

export async function handleFood(ctx: Ctx): Promise<Response> {
  const key = ctx.env.USDA_API_KEY;
  if (!key) throw new HttpError(500, "server_misconfigured", "The proxy is missing its food database credentials");

  const query = cleanQuery(ctx.url.searchParams.get("q"));
  const page = parsePage(ctx.url.searchParams.get("page"));

  // The cache key is the normalized query, so "Cheddar  CHEESE" and "cheddar cheese" share an entry.
  const cache = ctx.deps.getCache();
  const cacheKey = new Request(
    `${ctx.url.origin}/v1/food/search?q=${encodeURIComponent(query.toLowerCase())}&page=${page}`,
  );
  if (cache) {
    try {
      const hit = await cache.match(cacheKey);
      if (hit) return clientResponse(echoQuery(await hit.text(), query), "HIT");
    } catch {
      // A broken cache must never break search.
    }
  }

  // The key travels in a header (api.data.gov accepts X-Api-Key), so it never appears in a URL.
  const reservation = await reserveBudget(ctx, "food", FOOD_DAILY_REQUESTS);
  const url = `${USDA_SEARCH_URL}?query=${encodeURIComponent(query)}&pageSize=${FOOD_PAGE_SIZE}&pageNumber=${page}`;
  let upstream: Response;
  try {
    upstream = await fetchUpstream(ctx, url, { method: "GET", headers: { "x-api-key": key, accept: "application/json" } }, 20_000);
  } catch (error) {
    await refundBudget(ctx, reservation);
    throw error;
  }

  if (!upstream.ok) {
    // USDA blocks a key for an hour after exceeding 1,000 requests per hour.
    const failure = await upstreamFailure(ctx, upstream, { rateLimitFallbackSeconds: 3600 });
    if (isRefundable(failure)) await refundBudget(ctx, reservation);
    throw failure;
  }

  let raw: unknown;
  try {
    raw = await upstream.json();
  } catch {
    await refundBudget(ctx, reservation);
    throw new HttpError(502, "upstream_error", "The food database returned an unreadable response");
  }
  const body = JSON.stringify(normalizeSearch(raw, query, page));

  if (cache) {
    const stored = new Response(body, {
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": `public, max-age=${EDGE_CACHE_SECONDS}`,
      },
    });
    ctx.exec.waitUntil(
      (async () => {
        try {
          await cache.put(cacheKey, stored);
        } catch {
          // Caching is an optimization only.
        }
      })(),
    );
  }
  return clientResponse(body, "MISS");
}
