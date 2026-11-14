class ApiConstants {
  // Configured via compile-time environment or fallback to Lovable Cloud Edge Functions
  static const String supabaseUrl = String.fromEnvironment(
    'LOVABLE_SUPABASE_URL',
    defaultValue: 'https://flix-cloud-backend.lovable.app',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'LOVABLE_SUPABASE_ANON_KEY',
    defaultValue: 'public-anon-key-placeholder',
  );

  // TMDB Proxy / Edge Function URL (secrets stored server-side in Lovable Cloud)
  static const String tmdbProxyUrl = String.fromEnvironment(
    'LOVABLE_TMDB_PROXY_URL',
    defaultValue: 'https://flix-cloud-backend.lovable.app/functions/v1/tmdb-proxy',
  );

  static const String streamResolverUrl = String.fromEnvironment(
    'LOVABLE_STREAM_RESOLVER_URL',
    defaultValue: 'https://flix-cloud-backend.lovable.app/functions/v1/stream-resolver',
  );

  // Direct TMDB fallback when supplied via --dart-define
  static const String tmdbApiKey = String.fromEnvironment('TMDB_API_KEY', defaultValue: '');
  static const String tmdbReadToken = String.fromEnvironment('TMDB_READ_TOKEN', defaultValue: '');

  static const String tmdbBaseUrl = 'https://api.themoviedb.org/3';
  static const String tmdbImageBaseW500 = 'https://image.tmdb.org/t/p/w500';
  static const String tmdbImageBaseOriginal = 'https://image.tmdb.org/t/p/original';

  // Zarhosting Media Provider Endpoints
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
