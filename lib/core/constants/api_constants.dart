class ApiConstants {
  // Flix's dedicated Supabase project. The client embeds only this public URL;
  // no Supabase API, service-role, or secret key is compiled into the APK.
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://jewtsdupzwwkdoudwgyk.supabase.co',
  );
  // TMDB is called through Flix's Supabase Edge Function. The TMDB bearer
  // token is configured as a server-side Supabase secret, never compiled into
  // the APK.
  static const String tmdbProxyUrl = '$supabaseUrl/functions/v1/tmdb-proxy';
  static const String tmdbImageBaseW500 = 'https://image.tmdb.org/t/p/w500';
  static const String tmdbImageBaseOriginal = 'https://image.tmdb.org/t/p/original';

  // Zarhosting Media Provider Endpoints (same integration used by Hallyu TV)
  static const String zarhostingBaseUrl = 'https://movieapi.zarhosting.dpdns.org/api/public/v1';

  static const Map<String, String> zarhostingApiHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    'Referer': 'https://moviebox.ph/',
    'Accept': 'application/json',
  };

  // Primary ExoPlayer CDN headers profile required for media playback
  static const Map<String, String> zarhostingMediaHeaders = {
    'User-Agent': 'ExoPlayerLib/2.19.1',
    'Referer': 'https://www.movieboxpro.app/',
    'Origin': 'https://www.movieboxpro.app',
    'Accept': '*/*',
    'Accept-Encoding': 'identity',
  };

  // Fallback profiles if CDN rejects primary profile
  static const List<Map<String, String>> fallbackMediaHeaderProfiles = [
    {
      'User-Agent': 'MovieBoxPro/16.2.1 (Android 12; Pixel 6)',
      'Referer': 'https://www.movieboxpro.app/',
      'Origin': 'https://www.movieboxpro.app',
    },
    {
      'User-Agent': 'ExoPlayerLib/2.19.1',
      'Referer': 'https://moviebox.ph/',
      'Origin': 'https://moviebox.ph',
    },
    {
      'User-Agent': 'Mozilla/5.0',
      'Referer': 'https://moviebox.ph/',
      'Origin': 'https://moviebox.ph',
    },
  ];
}
