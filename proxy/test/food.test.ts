import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { FOOD_DAILY_REQUESTS, FOOD_MAX_PAGE, FOOD_PAGE_SIZE, USDA_SEARCH_URL, normalizeFood, normalizeSearch } from "../src/food.ts";
import { FAKE_USDA_KEY, errorOf, jsonUpstream, makeHarness } from "./helpers.ts";
import type { Harness } from "./helpers.ts";

// Shapes follow real FoodData Central /foods/search payloads (checked against the live API).
function nutrient(nutrientId: number, nutrientNumber: string, nutrientName: string, unitName: string, value: unknown) {
  return { nutrientId, nutrientName, nutrientNumber, unitName, value, derivationCode: "LCCS", rank: 100 };
}
const protein = (v: unknown) => nutrient(1003, "203", "Protein", "G", v);
const fat = (v: unknown) => nutrient(1004, "204", "Total lipid (fat)", "G", v);
const carbs = (v: unknown) => nutrient(1005, "205", "Carbohydrate, by difference", "G", v);
const kcal = (v: unknown) => nutrient(1008, "208", "Energy", "KCAL", v);
const kilojoules = (v: unknown) => nutrient(1062, "268", "Energy", "KJ", v);
const atwaterSpecific = (v: unknown) => nutrient(2048, "958", "Energy (Atwater Specific Factors)", "KCAL", v);

const cheddar = {
  fdcId: 2095236,
  description: "CHEDDAR CHEESE",
  dataType: "Branded",
  brandOwner: "MDS Foods Inc.",
  brandName: "AMISH CLASSICS",
  servingSizeUnit: "g",
  servingSize: 28,
  householdServingFullText: "1 ONZ",
  foodNutrients: [protein(25), fat(35.7), carbs(0), kcal(432)],
  foodMeasures: [],
};

const apple = {
  fdcId: 2709215,
  description: "Apple, raw",
  dataType: "Survey (FNDDS)",
  foodNutrients: [protein(0.17), fat(0.15), carbs(14.8), kcal(61)],
  foodMeasures: [
    { disseminationText: "Quantity not specified", gramWeight: 125, rank: 3 },
    { disseminationText: "1 cup, sliced", gramWeight: 110, rank: 2 },
    { disseminationText: "1 small", gramWeight: 165, rank: 1 },
    { disseminationText: "1 small", gramWeight: 165, rank: 4 },
    { disseminationText: "1 empty", gramWeight: 0, rank: 5 },
  ],
};

async function setup(): Promise<{ h: Harness; token: string }> {
  const h = makeHarness();
  const token = await h.install();
  h.upstream.handler = () => jsonUpstream({ totalHits: 2, currentPage: 1, totalPages: 1, foods: [cheddar, apple] });
  return { h, token };
}

function search(h: Harness, token: string, query: string) {
  return h.call(`/v1/food/search${query}`, { token });
}

describe("food normalization", () => {
  it("normalizes a branded food with its labelled serving", () => {
    assert.deepEqual(normalizeFood(cheddar), {
      fdcId: 2095236,
      name: "CHEDDAR CHEESE",
      brand: "AMISH CLASSICS",
      dataType: "Branded",
      per100g: { kcal: 432, protein: 25, carbs: 0, fat: 35.7 },
      servings: [{ label: "1 ONZ", grams: 28 }],
    });
  });

  it("keeps a reported zero as 0 but never turns a missing value into 0", () => {
    const item = normalizeFood({ fdcId: 1, description: "Water", foodNutrients: [carbs(0), protein(undefined)] });
    assert.deepEqual(item?.per100g, { kcal: null, protein: null, carbs: 0, fat: null });
  });

  it("returns null for missing, malformed or negative nutrient values", () => {
    const bad = [null, "12", Number.NaN, -3, {}, [1]];
    for (const value of bad) {
      const item = normalizeFood({ fdcId: 1, description: "X", foodNutrients: [protein(value), fat(value), carbs(value), kcal(value)] });
      assert.deepEqual(item?.per100g, { kcal: null, protein: null, carbs: null, fat: null }, JSON.stringify(value));
    }
    assert.deepEqual(normalizeFood({ fdcId: 1, description: "X" })?.per100g, {
      kcal: null,
      protein: null,
      carbs: null,
      fat: null,
    });
    assert.deepEqual(normalizeFood({ fdcId: 1, description: "X", foodNutrients: "oops" })?.per100g.kcal, null);
  });

  it("uses kcal when present and converts kJ only as a fallback", () => {
    const only = (...n: unknown[]) => normalizeFood({ fdcId: 1, description: "X", foodNutrients: n })?.per100g.kcal;
    assert.equal(only(kilojoules(1000)), 239); // 1000 kJ / 4.184 = 239.0 kcal
    assert.equal(only(kilojoules(1000), kcal(240)), 240, "kcal wins over kJ");
    assert.equal(only(kcal(240), kilojoules(1000)), 240, "order does not matter");
    assert.equal(only(atwaterSpecific(250), kilojoules(1000)), 250, "Atwater kcal beats kJ");
    assert.equal(only(kcal(61), atwaterSpecific(250)), 61, "plain kcal beats Atwater");
    assert.equal(only(kilojoules(255)), 60.9);
    assert.equal(only(kilojoules(0)), 0);
    // An energy entry whose unit says kJ is converted even under the kcal id.
    assert.equal(only(nutrient(1008, "208", "Energy", "kJ", 418.4)), 100);
    // A kcal entry with a bad value falls through to the next candidate.
    assert.equal(only(kcal(null), kilojoules(418.4)), 100);
  });

  it("matches nutrients by nutrientNumber when the id is absent", () => {
    const item = normalizeFood({
      fdcId: 1,
      description: "X",
      foodNutrients: [
        { nutrientNumber: "203", unitName: "G", value: 3 },
        { nutrientNumber: "204", unitName: "G", value: 4 },
        { nutrientNumber: "205", unitName: "G", value: 5 },
        { nutrientNumber: "208", unitName: "KCAL", value: 50 },
      ],
    });
    assert.deepEqual(item?.per100g, { kcal: 50, protein: 3, carbs: 5, fat: 4 });
  });

  it("converts milligram macros to grams", () => {
    const item = normalizeFood({ fdcId: 1, description: "X", foodNutrients: [nutrient(1003, "203", "Protein", "MG", 500)] });
    assert.equal(item?.per100g.protein, 0.5);
  });

  it("builds branded servings only from gram sizes", () => {
    const serving = (extra: Record<string, unknown>) => normalizeFood({ fdcId: 1, description: "X", ...extra })?.servings;
    assert.deepEqual(serving({ servingSize: 30, servingSizeUnit: "g" }), [{ label: "30 g", grams: 30 }]);
    assert.deepEqual(serving({ servingSize: 30.5, servingSizeUnit: "g", householdServingFullText: "  1 bar  " }), [
      { label: "1 bar", grams: 30.5 },
    ]);
    assert.equal(serving({ servingSize: 240, servingSizeUnit: "ml", householdServingFullText: "1 cup" }), undefined);
    assert.equal(serving({ servingSize: 0, servingSizeUnit: "g" }), undefined);
    assert.equal(serving({ servingSize: "28", servingSizeUnit: "g" }), undefined);
    assert.equal(serving({}), undefined);
  });

  it("orders household measures by rank, dedupes, and drops unusable ones", () => {
    assert.deepEqual(normalizeFood(apple)?.servings, [
      { label: "1 small", grams: 165 },
      { label: "1 cup, sliced", grams: 110 },
    ]);
    assert.equal("servings" in (normalizeFood({ fdcId: 1, description: "X", foodMeasures: [] }) ?? {}), false);
  });

  it("caps the number of servings", () => {
    const foodMeasures = Array.from({ length: 20 }, (_, i) => ({ disseminationText: `m${i}`, gramWeight: 10 + i, rank: i }));
    assert.equal(normalizeFood({ fdcId: 1, description: "X", foodMeasures })?.servings?.length, 8);
  });

  it("omits brand for generic foods and prefers brandName over brandOwner", () => {
    assert.equal("brand" in (normalizeFood(apple) ?? {}), false);
    assert.equal(normalizeFood({ fdcId: 1, description: "X", brandOwner: "Owner Inc." })?.brand, "Owner Inc.");
    assert.equal(normalizeFood({ fdcId: 1, description: "X", brandOwner: "Owner Inc.", brandName: "Brand" })?.brand, "Brand");
    assert.equal("brand" in (normalizeFood({ fdcId: 1, description: "X", brandName: "  " }) ?? {}), false);
  });

  it("drops entries without a usable id or name", () => {
    assert.equal(normalizeFood({ description: "X" }), null);
    assert.equal(normalizeFood({ fdcId: "1", description: "X" }), null);
    assert.equal(normalizeFood({ fdcId: 1.5, description: "X" }), null);
    assert.equal(normalizeFood({ fdcId: 1, description: "  " }), null);
    assert.equal(normalizeFood("food"), null);
    const result = normalizeSearch({ totalHits: 3, totalPages: 1, foods: [apple, { nope: true }, null] }, "apple", 1);
    assert.equal(result.results.length, 1);
  });

  it("defaults the envelope when USDA omits paging fields", () => {
    assert.deepEqual(normalizeSearch({}, "x", 2), { query: "x", page: 2, totalPages: 0, totalHits: 0, results: [] });
    assert.deepEqual(normalizeSearch("garbage", "x", 1).results, []);
  });
});

describe("food search route", () => {
  it("calls USDA with the server key in a header and returns the normalized shape", async () => {
    const { h, token } = await setup();
    const res = await search(h, token, "?q=cheddar%20cheese&page=2");
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("x-cache"), "MISS");
    assert.deepEqual(await res.json(), {
      query: "cheddar cheese",
      page: 2,
      totalPages: 1,
      totalHits: 2,
      results: [normalizeFood(cheddar), normalizeFood(apple)],
    });

    const call = h.calls.at(-1);
    const url = new URL(call?.url ?? "");
    assert.equal(`${url.origin}${url.pathname}`, USDA_SEARCH_URL);
    assert.equal(url.searchParams.get("query"), "cheddar cheese");
    assert.equal(url.searchParams.get("pageSize"), String(FOOD_PAGE_SIZE));
    assert.equal(url.searchParams.get("pageNumber"), "2");
    assert.equal(call?.headers.get("x-api-key"), FAKE_USDA_KEY);
    assert.ok(!call?.url.includes(FAKE_USDA_KEY), "the key must not appear in the URL");
    assert.equal(url.searchParams.get("api_key"), null);
  });

  it("defaults to page 1 and collapses whitespace and control characters in q", async () => {
    const { h, token } = await setup();
    await search(h, token, "?q=%20%20greek%09%0Ayogurt%20%20");
    const url = new URL(h.calls.at(-1)?.url ?? "");
    assert.equal(url.searchParams.get("query"), "greek yogurt");
    assert.equal(url.searchParams.get("pageNumber"), "1");
  });

  it("limits q length and validates page", async () => {
    const { h, token } = await setup();
    for (const q of ["", "?q=", "?q=%20%20%20", "?q=a", `?q=${"a".repeat(101)}`]) {
      const err = await errorOf(await search(h, token, q));
      assert.deepEqual([err.status, err.code], [400, "invalid_query"], q);
    }
    assert.equal((await search(h, token, `?q=${"a".repeat(100)}`)).status, 200);
    assert.equal((await search(h, token, "?q=ab")).status, 200);

    const before = h.calls.length;
    for (const page of ["0", "-1", "abc", "1.5", String(FOOD_MAX_PAGE + 1), "9999", "1e1"]) {
      const err = await errorOf(await search(h, token, `?q=apple&page=${page}`));
      assert.deepEqual([err.status, err.code], [400, "invalid_page"], page);
    }
    assert.equal(h.calls.length, before);
    assert.equal((await search(h, token, `?q=apple&page=${FOOD_MAX_PAGE}`)).status, 200);
  });

  it("serves repeat searches from the edge cache, including normalized variants", async () => {
    const { h, token } = await setup();
    const first = await search(h, token, "?q=Cheddar%20%20CHEESE");
    assert.equal(first.headers.get("x-cache"), "MISS");
    const firstBody = await first.text();
    await h.flush();
    assert.equal(h.cache.puts, 1);
    assert.equal(h.calls.length, 1);

    for (const variant of ["?q=cheddar%20cheese", "?q=%20cheddar%20CHEESE%20&page=1"]) {
      const hit = await search(h, token, variant);
      assert.equal(hit.status, 200);
      assert.equal(hit.headers.get("x-cache"), "HIT", variant);
      // Same results; only the echoed query is this caller's own (normalized) spelling.
      const body = (await hit.json()) as { query: string };
      const expectedQuery = variant.includes("%20cheddar%20CHEESE%20") ? "cheddar CHEESE" : "cheddar cheese";
      assert.equal(body.query, expectedQuery, variant);
      assert.deepEqual(JSON.stringify({ ...body, query: "Cheddar CHEESE" }), firstBody, variant);
    }
    assert.equal(h.calls.length, 1, "cache hits never call USDA");

    const otherPage = await search(h, token, "?q=cheddar%20cheese&page=2");
    assert.equal(otherPage.headers.get("x-cache"), "MISS");
    const otherQuery = await search(h, token, "?q=swiss%20cheese");
    assert.equal(otherQuery.headers.get("x-cache"), "MISS");
    assert.equal(h.calls.length, 3);
  });

  it("stores entries for a day and still requires auth on a cache hit", async () => {
    const { h, token } = await setup();
    await search(h, token, "?q=apple");
    await h.flush();
    const stored = [...h.cache.entries.keys()][0] ?? "";
    assert.ok(stored.includes("q=apple"));
    assert.ok(!stored.includes(token) && !stored.includes(FAKE_USDA_KEY));

    const anonymous = await h.call("/v1/food/search?q=apple");
    assert.equal(anonymous.status, 401);
    assert.equal(h.cache.matches, 1, "an unauthenticated request never reaches the cache");
  });

  it("does not cache failures", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream({ message: "oops" }, 500);
    assert.equal((await search(h, token, "?q=apple")).status, 502);
    await h.flush();
    assert.equal(h.cache.puts, 0);
    h.upstream.handler = () => new Response("not json", { status: 200 });
    assert.equal((await errorOf(await search(h, token, "?q=apple"))).code, "upstream_error");
    await h.flush();
    assert.equal(h.cache.puts, 0);
  });

  it("keeps working when the cache throws or is unavailable", async () => {
    const { h, token } = await setup();
    h.cache.failMatch = true;
    assert.equal((await search(h, token, "?q=apple")).status, 200);

    const bare = makeHarness({ cache: false });
    const bareToken = await bare.install();
    bare.upstream.handler = () => jsonUpstream({ totalHits: 0, totalPages: 0, foods: [] });
    assert.equal((await search(bare, bareToken, "?q=apple")).status, 200);
    assert.equal((await search(bare, bareToken, "?q=apple")).status, 200);
    assert.equal(bare.calls.length, 2);
  });

  it("maps USDA rate limits and key problems", async () => {
    const { h, token } = await setup();
    h.upstream.handler = () => jsonUpstream({ error: { code: "OVER_RATE_LIMIT" } }, 429);
    const limited = await search(h, token, "?q=apple");
    assert.equal(limited.status, 429);
    assert.equal(limited.headers.get("retry-after"), "3600");
    assert.equal((await errorOf(limited)).code, "upstream_rate_limited");

    h.upstream.handler = () => jsonUpstream({}, 429, { "retry-after": "120" });
    assert.equal((await search(h, token, "?q=apple")).headers.get("retry-after"), "120");

    h.upstream.handler = () => jsonUpstream({ error: { code: "API_KEY_INVALID", message: "bad key" } }, 403);
    const key = await search(h, token, "?q=apple");
    const err = await errorOf(key);
    assert.deepEqual([err.status, err.code], [502, "upstream_unauthorized"]);
    assert.ok(!err.message.includes("bad key"));
  });

  it("returns 500 when the USDA key is not configured", async () => {
    const h = makeHarness({ env: { USDA_API_KEY: undefined } });
    const token = await h.install();
    const err = await errorOf(await search(h, token, "?q=apple"));
    assert.deepEqual([err.status, err.code], [500, "server_misconfigured"]);
    assert.equal(h.calls.length, 0);
  });

  it("marks results private to the client and never exposes USDA bookkeeping", async () => {
    const { h, token } = await setup();
    const res = await search(h, token, "?q=apple");
    assert.match(res.headers.get("cache-control") ?? "", /private/);
    const text = await res.text();
    assert.ok(!text.includes("derivationCode"));
    assert.ok(!text.includes("foodNutrientId"));
  });
});

// Trimmed from live /foods/search responses (DEMO_KEY, 2026-10-29): one food per USDA data type.
describe("food normalization against real payload shapes", () => {
  const branded = (extra: Record<string, unknown>) => ({
    fdcId: 2616918,
    description: "WHOLE MILK",
    dataType: "Branded",
    brandOwner: "Some Dairy",
    householdServingFullText: "1 cup (240mL)",
    foodNutrients: [protein(3.33), fat(3.33), carbs(5), kcal(62)],
    ...extra,
  });

  it("flags branded liquids, whose per-100 values are per 100 ml, and leaves solids unflagged", () => {
    for (const unit of ["ml", "MLT", "ML", " mlt "]) {
      const item = normalizeFood(branded({ servingSize: 240, servingSizeUnit: unit }));
      assert.equal(item?.basis, "ml", unit);
      assert.equal(item?.per100g.kcal, 62);
      assert.equal(item?.servings, undefined, "a millilitre serving cannot be converted to grams");
    }
    for (const unit of ["g", "GRM", "oz", undefined]) {
      const item = normalizeFood(branded({ servingSize: 28, servingSizeUnit: unit }));
      assert.equal(item?.basis, undefined, String(unit));
    }
    assert.equal(normalizeFood(apple)?.basis, undefined);
  });

  it("reads Foundation energy from the Atwater ids when kcal 1008 is absent, preferring the specific factors", () => {
    const foundation = {
      fdcId: 2646170,
      description: "Chicken, breast, boneless, skinless, raw",
      dataType: "Foundation",
      foodNutrients: [fat(1.93), protein(22.5), carbs(0), nutrient(2047, "957", "Energy (Atwater General Factors)", "KCAL", 106), atwaterSpecific(112)],
    };
    assert.deepEqual(normalizeFood(foundation)?.per100g, { kcal: 112, protein: 22.5, carbs: 0, fat: 1.93 });
    const general = { ...foundation, foodNutrients: foundation.foodNutrients.filter((n) => n.nutrientId !== 2048) };
    assert.equal(normalizeFood(general)?.per100g.kcal, 106);
  });

  it("prefers kcal over kJ when SR Legacy lists both, and accepts the lower-case kJ unit USDA really sends", () => {
    const sr = {
      fdcId: 171474,
      description: "Chicken, broilers or fryers, breast, meat and skin, raw",
      dataType: "SR Legacy",
      foodNutrients: [protein(20.8), fat(9.25), carbs(0), kcal(172), nutrient(1062, "268", "Energy", "kJ", 720)],
    };
    assert.equal(normalizeFood(sr)?.per100g.kcal, 172);
    const kjOnly = { ...sr, foodNutrients: [protein(20.8), nutrient(1062, "268", "Energy", "kJ", 720)] };
    assert.equal(normalizeFood(kjOnly)?.per100g.kcal, 172.1);
    assert.equal(normalizeFood(kjOnly)?.per100g.fat, null, "a missing macro is null, not 0");
    assert.equal(normalizeFood(kjOnly)?.per100g.carbs, null);
  });

  it("keeps household measures for Survey foods and drops 'Quantity not specified'", () => {
    const survey = {
      fdcId: 2705955,
      description: "Chicken breast, baked, broiled, or roasted, skin eaten",
      dataType: "Survey (FNDDS)",
      foodNutrients: [protein(26.25), fat(8.8), carbs(0), kcal(192)],
      foodMeasures: [
        { disseminationText: "1 breast quarter (yield after cooking, bone removed)", gramWeight: 155, rank: 9, measureUnitName: "undetermined" },
        { disseminationText: "1 small or thin slice", gramWeight: 30, rank: 5 },
        { disseminationText: "Quantity not specified", gramWeight: 130, rank: 10 },
      ],
    };
    assert.deepEqual(normalizeFood(survey)?.servings, [
      { label: "1 small or thin slice", grams: 30 },
      { label: "1 breast quarter (yield after cooking, bone removed)", grams: 155 },
    ]);
  });

  it("treats branded GRM like g and ignores a zero or missing serving size", () => {
    assert.deepEqual(normalizeFood(branded({ servingSize: 28, servingSizeUnit: "GRM", householdServingFullText: "1 ONZ" }))?.servings, [{ label: "1 ONZ", grams: 28 }]);
    assert.equal(normalizeFood(branded({ servingSize: 0, servingSizeUnit: "g" }))?.servings, undefined);
    assert.equal(normalizeFood(branded({ servingSizeUnit: "g" }))?.servings, undefined);
  });
});

describe("food search hardening", () => {
  it("builds the USDA query string from validated values only", async () => {
    const h = makeHarness({ cache: false });
    const token = await h.install();
    h.upstream.handler = () => jsonUpstream({ totalHits: 0, totalPages: 0, foods: [] });
    const hostile = [
      "?q=apple&api_key=EVIL&pageSize=1000&dataType=Branded&sortBy=x&format=xml",
      "?q=apple%26api_key%3DEVIL%26pageSize%3D1000",
      "?q=apple%23fragment%3Fmore",
      "?q=apple&q=pear&page=2&page=3",
      "?q=%22apple%22%20%2Bpie%20-crust",
      "?q=a%00b%0d%0aX-Injected:%201",
      "?q=%E8%8B%B9%E6%9E%9C",
      "?q=apple&pageNumber=40&pageSize=200&query=other",
    ];
    for (const query of hostile) {
      await search(h, token, query);
      const url = new URL(h.calls.at(-1)?.url ?? "");
      assert.deepEqual([...url.searchParams.keys()].sort(), ["pageNumber", "pageSize", "query"], query);
      assert.equal(url.searchParams.get("pageSize"), String(FOOD_PAGE_SIZE), query);
      assert.equal(url.hash, "", query);
      assert.ok(!/[\r\n\u0000]/.test(url.search), query);
    }
    await search(h, token, "?q=apple%26api_key%3DEVIL");
    assert.equal(new URL(h.calls.at(-1)?.url ?? "").searchParams.get("query"), "apple&api_key=EVIL", "an ampersand stays inside the query value");
    await search(h, token, "?q=a%00b%0d%0aX-Injected:%201");
    assert.equal(new URL(h.calls.at(-1)?.url ?? "").searchParams.get("query"), "a b X-Injected: 1");
    assert.equal(h.calls.at(-1)?.headers.get("x-injected"), null);
  });

  it("uses the first value when q or page is repeated", async () => {
    const { h, token } = await setup();
    await search(h, token, "?q=first&q=second&page=2&page=abc");
    const url = new URL(h.calls.at(-1)?.url ?? "");
    assert.equal(url.searchParams.get("query"), "first");
    assert.equal(url.searchParams.get("pageNumber"), "2");
  });

  it("budgets calls to USDA per token, not cache hits", async () => {
    const h = makeHarness();
    const token = await h.install();
    h.upstream.handler = () => jsonUpstream({ totalHits: 0, totalPages: 0, foods: [] });
    for (let i = 0; i < FOOD_DAILY_REQUESTS; i += 1) {
      assert.equal((await search(h, token, `?q=apple${i}`)).status, 200, `search ${i + 1}`);
    }
    const blocked = await search(h, token, "?q=one-more");
    const err = await errorOf(blocked.clone());
    assert.deepEqual([err.status, err.code], [429, "daily_budget_exceeded"]);
    assert.equal(blocked.headers.get("retry-after"), String(12 * 3600));
    assert.equal(h.calls.length, FOOD_DAILY_REQUESTS, "a refused search never reaches USDA");

    // Another install is unaffected.
    const other = await h.install("203.0.113.2");
    assert.equal((await search(h, other, "?q=pear")).status, 200);
  });

  it("serves cached searches even after the budget is spent, and charges nothing for them", async () => {
    const { h, token } = await setup();
    await search(h, token, "?q=cheddar");
    await h.flush();
    const key = h.kv.keys().find((k) => k.includes(":food:"));
    assert.ok(key);
    h.kv.store.set(key, { value: String(FOOD_DAILY_REQUESTS), expiresAt: null });
    const hit = await search(h, token, "?q=cheddar");
    assert.equal(hit.status, 200);
    assert.equal(hit.headers.get("x-cache"), "HIT");
    assert.equal(h.kv.store.get(key)?.value, String(FOOD_DAILY_REQUESTS));
    const miss = await search(h, token, "?q=something-new");
    assert.equal((await errorOf(miss)).code, "daily_budget_exceeded");
  });

  it("refunds a search when USDA fails on its side but not when it rejects the query", async () => {
    const { h, token } = await setup();
    const used = () => Number(h.kv.store.get(h.kv.keys().find((k) => k.includes(":food:")) ?? "")?.value ?? 0);
    h.upstream.handler = () => jsonUpstream({}, 503);
    await search(h, token, "?q=apple");
    assert.equal(used(), 0);
    h.upstream.handler = () => new Response("garbage", { status: 200 });
    await search(h, token, "?q=apple");
    assert.equal(used(), 0);
    h.upstream.handler = () => {
      throw new TypeError("down");
    };
    await search(h, token, "?q=apple");
    assert.equal(used(), 0);
    h.upstream.handler = () => jsonUpstream({ error: { message: "bad query" } }, 400);
    assert.equal((await search(h, token, "?q=apple")).status, 400);
    assert.equal(used(), 1);
  });
});
