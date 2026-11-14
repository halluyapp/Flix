const TMDB_API_BASE = "https://api.themoviedb.org/3";
const allowedFixedPaths = new Set([
  "/trending/all/day",
  "/trending/all/week",
  "/movie/top_rated",
  "/tv/top_rated",
  "/movie/popular",
  "/tv/popular",
  "/movie/upcoming",
  "/search/multi",
  "/discover/movie",
  "/discover/tv",
]);
const allowedQueryKeys = new Set([
  "query",
  "page",
  "language",
  "region",
  "sort_by",
  "with_original_language",
  "with_origin_country",
  "with_genres",
  "include_adult",
  "primary_release_year",
  "first_air_date_year",
]);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "public, max-age=60, s-maxage=120",
};

function isAllowedPath(path: string): boolean {
  if (allowedFixedPaths.has(path)) return true;
  return /^\/tv\/\d+\/season\/\d+$/.test(path);
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
  return window.count > 90;
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

  const token = Deno.env.get("TMDB_READ_TOKEN");
  if (!token) {
    return new Response(JSON.stringify({ error: "Catalogue service is not configured" }), {
      status: 503,
      headers: corsHeaders,
    });
  }

  try {
    const requestUrl = new URL(request.url);
    const path = requestUrl.searchParams.get("path") ?? "";
    if (!isAllowedPath(path)) {
      return new Response(JSON.stringify({ error: "Unsupported catalogue endpoint" }), {
        status: 400,
        headers: corsHeaders,
      });
    }

    const upstreamUrl = new URL(`${TMDB_API_BASE}${path}`);
    for (const [key, value] of requestUrl.searchParams.entries()) {
      if (key === "path" || !allowedQueryKeys.has(key)) continue;
      if (key === "page") {
        const page = Number.parseInt(value, 10);
        if (!Number.isFinite(page) || page < 1 || page > 20) continue;
      }
      if (value.length > 160) continue;
      upstreamUrl.searchParams.set(key, value);
    }

    const upstream = await fetch(upstreamUrl, {
      headers: {
        "Accept": "application/json",
        "Authorization": `Bearer ${token}`,
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (!upstream.ok) {
      return new Response(JSON.stringify({ error: "Catalogue provider request failed" }), {
        status: 502,
        headers: corsHeaders,
      });
    }

    const payload = await upstream.text();
    return new Response(payload, {
      status: 200,
      headers: corsHeaders,
    });
  } catch (_) {
    return new Response(JSON.stringify({ error: "Catalogue service is temporarily unavailable" }), {
      status: 502,
      headers: corsHeaders,
    });
  }
});
