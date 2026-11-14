const PROVIDER_API = "https://movieapi.zarhosting.dpdns.org/api/public/v1";
const SEARCH_TERMS = [
  "animated short film",
  "short animation",
  "animation short",
  "short film",
];

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "public, max-age=60, s-maxage=120",
};

const providerHeaders = {
  "User-Agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/122.0.0.0 Mobile Safari/537.36",
  "Referer": "https://moviebox.ph/",
  "Accept": "application/json",
};

const shortGenres = new Set(["short", "shorts", "short film", "short films"]);
const excludedGenres = new Set([
  "adult", "erotic", "hot", "porn", "xxx", "sexual", "hentai", "nsfw",
  "18+", "18 plus", "r18", "r-18", "nc-17",
]);
const adultRating = /^(?:18(?:\+| plus)?|r-?18|nc-?17|xxx|adult(?:s)?(?: only)?)$/i;
const explicitTitle = /\b(?:porn|xxx|erotic|hentai|milf|orgy|nude|fuck(?:ed|ing|s)?)\b/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asText(value: unknown): string {
  return value == null ? "" : String(value).trim();
}

function normalizedTitle(value: string): string {
  return value
    .toLowerCase()
    .replace(/\[[^\]]*\]/g, " ")
    .replace(/\([^)]*\)/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function isAffirmative(value: unknown): boolean {
  if (value === true || value === 1) return true;
  return new Set(["true", "yes", "1", "adult", "nsfw"]).has(asText(value).toLowerCase());
}

function isMarkedAdult(raw: Record<string, unknown>): boolean {
  const adultFlags = [
    raw.adult,
    raw.is_adult,
    raw.isAdult,
    raw.adult_content,
    raw.explicit,
    raw.nsfw,
    raw.is_nsfw,
  ];
  if (adultFlags.some(isAffirmative)) return true;

  const ageRating = asText(raw.age_rating ?? raw.content_rating ?? raw.maturity_rating);
  return ageRating.length > 0 && adultRating.test(ageRating);
}

function parseShortMovie(raw: unknown): Record<string, unknown> | null {
  if (!isRecord(raw)) return null;

  const type = asText(raw.type ?? raw.subject_type).toLowerCase();
  if (type !== "movie" || isMarkedAdult(raw)) return null;
  if (raw.has_resource !== true && raw.hasResource !== true) return null;

  const rawGenres = raw.genre ?? raw.genres;
  const genres = Array.isArray(rawGenres)
    ? rawGenres.map(asText).filter(Boolean)
    : asText(rawGenres).split(",").map((tag) => tag.trim()).filter(Boolean);
  const genreSet = new Set(genres.map((tag) => tag.toLowerCase()));
  if (![...genreSet].some((tag) => shortGenres.has(tag))) return null;
  if ([...genreSet].some((tag) => excludedGenres.has(tag))) return null;

  const title = asText(raw.base_title ?? raw.name ?? raw.title ?? raw.subject_title);
  if (!title || explicitTitle.test(title)) return null;

  const subjectId = asText(raw.subject_id ?? raw.subjectId ?? raw.id);
  const detailPath = asText(raw.detail_path ?? raw.detailPath ?? raw.slug);
  if (!subjectId || !detailPath) return null;

  const rawYear = asText(raw.year ?? raw.release_year ?? raw.release_date);
  const year = Number.parseInt(rawYear.slice(0, 4), 10) || 0;
  const ratingValue = Number.parseFloat(asText(raw.rating ?? raw.vote_average));
  const posterUrl = asText(raw.poster_url ?? raw.posterUrl);

  return {
    type: "movie",
    has_resource: true,
    subject_id: subjectId,
    detail_path: detailPath,
    slug: detailPath,
    name: title,
    title,
    poster_url: posterUrl.startsWith("https://") ? posterUrl : "",
    genre: genres.join(","),
    country: asText(raw.country),
    description: asText(raw.description ?? raw.overview),
    year,
    rating: Number.isFinite(ratingValue) ? ratingValue : 0,
  };
}

async function searchProvider(query: string, page: number) {
  try {
    const url = new URL(`${PROVIDER_API}/search`);
    url.searchParams.set("q", query);
    url.searchParams.set("page", String(page));
    url.searchParams.set("per_page", "30");

    const response = await fetch(url, {
      headers: providerHeaders,
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) return { items: [], hasMore: false };

    const decoded: unknown = await response.json();
    const root = isRecord(decoded) && isRecord(decoded.data) ? decoded.data : decoded;
    const rawItems = isRecord(root)
      ? root.items ?? root.results ?? root.data ?? []
      : root;
    const items = Array.isArray(rawItems)
      ? rawItems.map(parseShortMovie).filter((item): item is Record<string, unknown> => item !== null)
      : [];
    const hasMore = isRecord(root) && (root.has_more === true || root.hasMore === true);
    return { items, hasMore };
  } catch (_) {
    return { items: [], hasMore: false };
  }
}

function recordKey(item: Record<string, unknown>): string {
  return `${normalizedTitle(asText(item.title))}_${asText(item.year)}`;
}

type RateWindow = { count: number; resetAt: number };
const rateWindows = new Map<string, RateWindow>();

function isRateLimited(request: Request): boolean {
  const forwardedFor = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  const clientId = (
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-real-ip") ??
    forwardedFor ??
    "unknown"
  ).trim();
  const now = Date.now();
  if (rateWindows.size >= 2_048 && !rateWindows.has(clientId)) {
    for (const [key, entry] of rateWindows) {
      if (entry.resetAt <= now) rateWindows.delete(key);
    }
    if (rateWindows.size >= 2_048) {
      const oldestClient = rateWindows.keys().next().value;
      if (oldestClient !== undefined) rateWindows.delete(oldestClient);
    }
  }
  const window = rateWindows.get(clientId);
  if (!window || window.resetAt <= now) {
    rateWindows.set(clientId, { count: 1, resetAt: now + 60_000 });
    return false;
  }
  window.count += 1;
  return window.count > 30;
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "GET") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: corsHeaders,
    });
  }
  if (isRateLimited(request)) {
    return new Response(JSON.stringify({ error: "Request limit reached; retry shortly" }), {
      status: 429,
      headers: { ...corsHeaders, "Cache-Control": "no-store", "Retry-After": "60" },
    });
  }

  try {
    const url = new URL(request.url);
    const parsedLimit = Number.parseInt(url.searchParams.get("limit") ?? "24", 10);
    const limit = Number.isFinite(parsedLimit) ? Math.min(48, Math.max(1, parsedLimit)) : 24;
    const firstPages = await Promise.all(SEARCH_TERMS.map((term) => searchProvider(term, 1)));
    const itemsByTitle = new Map<string, Record<string, unknown>>();

    const addItems = (items: Record<string, unknown>[]) => {
      for (const item of items) {
        const key = recordKey(item);
        const existing = itemsByTitle.get(key);
        if (!existing || Number(item.rating) > Number(existing.rating)) {
          itemsByTitle.set(key, item);
        }
      }
    };

    for (const page of firstPages) addItems(page.items);

    if (itemsByTitle.size < 18) {
      const followups = firstPages
        .map((page, index) => page.hasMore ? SEARCH_TERMS[index] : null)
        .filter((term): term is string => term !== null)
        .map((term) => searchProvider(term, 2));
      for (const page of await Promise.all(followups)) addItems(page.items);
    }

    const items = [...itemsByTitle.values()]
      .sort((a, b) => Number(b.rating) - Number(a.rating) || Number(b.year) - Number(a.year))
      .slice(0, limit);

    return new Response(JSON.stringify({ source: "zarhosting", count: items.length, items }), {
      status: 200,
      headers: corsHeaders,
    });
  } catch (_) {
    return new Response(JSON.stringify({ error: "Short-film catalogue is temporarily unavailable" }), {
      status: 502,
      headers: corsHeaders,
    });
  }
});
