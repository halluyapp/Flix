import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ZARHOSTING_API_BASE = "https://movieapi.zarhosting.dpdns.org/api/public/v1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const JSON_API_HEADERS = {
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
  "Referer": "https://moviebox.ph/",
  "Accept": "application/json, text/plain, */*",
};

const MEDIA_PLAYBACK_HEADERS = {
  "User-Agent": "ExoPlayerLib/2.19.1",
  "Referer": "https://www.movieboxpro.app/",
  "Origin": "https://www.movieboxpro.app",
  "Accept": "*/*",
  "Accept-Encoding": "identity",
};

function normalizeTitle(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[\s\-_:,.!?\'"\(\)\[\]]+/g, " ")
    .replace(/[^a-z0-9 ]/g, "")
    .trim();
}

function calculateSimilarity(s1: string, s2: string): number {
  const n1 = normalizeTitle(s1);
  const n2 = normalizeTitle(s2);
  if (n1 === n2) return 1.0;
  if (n1.includes(n2) || n2.includes(n1)) return 0.85;
  const words1 = new Set(n1.split(" ").filter(w => w.length > 1));
  const words2 = new Set(n2.split(" ").filter(w => w.length > 1));
  if (words1.size === 0 || words2.size === 0) return 0.0;
  let matches = 0;
  for (const w of words1) {
    if (words2.has(w)) matches++;
  }
  return (2.0 * matches) / (words1.size + words2.size);
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { title, year, isSeries, season, episode, tmdbId } = await req.json();

    if (!title) {
      return new Response(JSON.stringify({ error: "Title parameter is required" }), {
        status: 400,
        headers: corsHeaders,
      });
    }

    const targetSeason = season || 1;
    const targetEpisode = episode || 1;
    const cacheKey = `${normalizeTitle(title)}_${year || "any"}_${isSeries ? `s${targetSeason}e${targetEpisode}` : "movie"}`;

    // 1. Check Supabase Stream Cache
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    let supabase: any = null;
    if (supabaseUrl && supabaseKey) {
      supabase = createClient(supabaseUrl, supabaseKey);
      const { data: cached } = await supabase
        .from("stream_cache")
        .select("*")
        .eq("cache_key", cacheKey)
        .gt("expires_at", new Date().toISOString())
        .maybeSingle();

      if (cached && cached.sources_json && cached.sources_json.length > 0) {
        return new Response(
          JSON.stringify({
            subjectId: cached.subject_id,
            title: cached.title,
            sources: cached.sources_json,
            captions: cached.captions_json || [],
            headers: MEDIA_PLAYBACK_HEADERS,
            cached: true,
          }),
          { status: 200, headers: corsHeaders }
        );
      }
    }

    // 2. Query Zarhosting Search
    const searchUrl = `${ZARHOSTING_API_BASE}/search?q=${encodeURIComponent(title.trim())}`;
    const searchRes = await fetch(searchUrl, { headers: JSON_API_HEADERS });
    if (!searchRes.ok) {
      return new Response(JSON.stringify({ error: `Search upstream error: ${searchRes.status}` }), {
        status: 502,
        headers: corsHeaders,
      });
    }

    const searchData = await searchRes.json();
    const items: any[] = Array.isArray(searchData) ? searchData : (searchData.data || searchData.results || []);

    if (items.length === 0) {
      return new Response(JSON.stringify({ error: "No matching titles found in provider" }), {
        status: 404,
        headers: corsHeaders,
      });
    }

    // 3. Strict Metadata Matching
    let bestMatch: any = null;
    let highestScore = 0.0;

    for (const item of items) {
      const itemTitle = item.title || item.name || item.subject_title || "";
      const itemYearStr = String(item.year || item.release_year || item.release_date || "");
      const itemYear = parseInt(itemYearStr.slice(0, 4), 10) || 0;
      const itemIsSeries = item.type === "tv" || item.type === "series" || item.is_series === true || (item.seasons && item.seasons.length > 0);

      if (isSeries !== undefined && isSeries !== itemIsSeries) {
        continue;
      }

      const sim = calculateSimilarity(title, itemTitle);
      if (sim < 0.6) continue;

      let score = sim * 100;
      if (year && itemYear > 0) {
        const diff = Math.abs(year - itemYear);
        if (diff === 0) score += 20;
        else if (diff <= 1) score += 10;
        else score -= 15;
      }

      if (score > highestScore) {
        highestScore = score;
        bestMatch = item;
      }
    }

    if (!bestMatch || highestScore < 60) {
      return new Response(JSON.stringify({ error: "No reliable match found for title" }), {
        status: 404,
        headers: corsHeaders,
      });
    }

    const subjectId = String(bestMatch.id || bestMatch.subject_id);

    // 4. Resolve Stream URL
    let streamUrl = `${ZARHOSTING_API_BASE}/stream/${subjectId}`;
    if (isSeries) {
      streamUrl += `?season=${targetSeason}&episode=${targetEpisode}`;
    }

    const streamRes = await fetch(streamUrl, { headers: JSON_API_HEADERS });
    if (!streamRes.ok) {
      return new Response(JSON.stringify({ error: `Stream upstream error: ${streamRes.status}` }), {
        status: 502,
        headers: corsHeaders,
      });
    }

    const streamData = await streamRes.json();
    const rawSources = Array.isArray(streamData)
      ? streamData
      : (streamData.sources || streamData.streams || streamData.data || []);

    const sources = rawSources
      .filter((s: any) => {
        const u = s.url || s.file || s.stream_url;
        return typeof u === "string" && u.startsWith("https://");
      })
      .map((s: any) => ({
        url: s.url || s.file || s.stream_url,
        quality: String(s.quality || s.resolution || "720p"),
        format: String(s.format || (s.url?.includes(".m3u8") ? "hls" : "mp4")),
        duration: typeof s.duration === "number" ? s.duration : parseInt(s.duration || "0", 10),
        sizeBytes: typeof s.size === "number" ? s.size : parseInt(s.size || "0", 10),
        isPreview: Boolean(s.is_preview || (s.duration && s.duration > 0 && s.duration < 180)),
      }));

    // 5. Fetch Captions
    let captions: any[] = [];
    try {
      const capRes = await fetch(`${ZARHOSTING_API_BASE}/stream/${subjectId}/captions`, { headers: JSON_API_HEADERS });
      if (capRes.ok) {
        const capData = await capRes.json();
        const rawCaps = Array.isArray(capData) ? capData : (capData.captions || capData.subtitles || capData.data || []);
        captions = rawCaps
          .filter((c: any) => c.url && c.url.startsWith("https://"))
          .map((c: any) => ({
            language: c.language || c.lang || "en",
            label: c.label || c.name || "English",
            url: c.url,
            isDefault: Boolean(c.is_default || c.default),
          }));
      }
    } catch (_) {
      // Non-fatal
    }

    // 6. Cache into stream_cache if Supabase is active
    if (supabase && sources.length > 0) {
      await supabase.from("stream_cache").upsert({
        cache_key: cacheKey,
        subject_id: subjectId,
        title: bestMatch.title || title,
        media_type: isSeries ? "tv" : "movie",
        season: isSeries ? targetSeason : null,
        episode: isSeries ? targetEpisode : null,
        sources_json: sources,
        captions_json: captions,
        expires_at: new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
      }, { onConflict: "cache_key" });
    }

    return new Response(
      JSON.stringify({
        subjectId,
        title: bestMatch.title || title,
        sources,
        captions,
        headers: MEDIA_PLAYBACK_HEADERS,
        cached: false,
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    return new Response(
      JSON.stringify({ error: error?.message || "Internal Server Error" }),
      { status: 500, headers: corsHeaders }
    );
  }
});
