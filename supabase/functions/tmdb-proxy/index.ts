import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const TMDB_BASE_URL = "https://api.themoviedb.org/3";
const TMDB_API_KEY = Deno.env.get("TMDB_API_KEY") || "";
const TMDB_ACCESS_TOKEN = Deno.env.get("TMDB_READ_ACCESS_TOKEN") || "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const path = url.searchParams.get("path") || "/trending/all/day";
    const cleanPath = path.startsWith("/") ? path : `/${path}`;
    
    // Build query params forward
    const forwardUrl = new URL(`${TMDB_BASE_URL}${cleanPath}`);
    for (const [key, value] of url.searchParams.entries()) {
      if (key !== "path") {
        forwardUrl.searchParams.set(key, value);
      }
    }

    const headers: Record<string, string> = {
      "Accept": "application/json",
    };

    if (TMDB_ACCESS_TOKEN) {
      headers["Authorization"] = `Bearer ${TMDB_ACCESS_TOKEN}`;
    } else if (TMDB_API_KEY) {
      forwardUrl.searchParams.set("api_key", TMDB_API_KEY);
    }

    const res = await fetch(forwardUrl.toString(), { headers });
    const data = await res.json();

    return new Response(JSON.stringify(data), {
      status: res.status,
      headers: corsHeaders,
    });
  } catch (error: any) {
    return new Response(
      JSON.stringify({ error: error?.message || "Internal Server Error" }),
      { status: 500, headers: corsHeaders }
    );
  }
});
