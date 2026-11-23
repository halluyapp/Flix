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
  static const String tmdbImageBaseOriginal =
      'https://image.tmdb.org/t/p/original';

  // MovieBox H5 API Endpoints (replaces dead Zarhosting provider)
  static const String movieboxBaseUrl =
      'https://h5-api.aoneroom.com/wefeed-h5api-bff';
  static const String movieboxHost = 'moviebox.ph';
  static const String movieboxSiteUrl = 'https://moviebox.ph';

  // Required headers for MovieBox H5 API calls
  static const Map<String, String> movieboxApiHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Referer': 'https://moviebox.ph/',
    'Origin': 'https://moviebox.ph',
    'Accept': 'application/json',
    'X-Client-Info': '{"timezone":"Africa/Lagos"}',
  };

  // Primary verified media & streaming headers required by MovieBox CDN (hakunaymatata CDN).
  // The CDN strictly allows mobile/browser clients with moviebox.ph referer/origin
  // and rejects bare ExoPlayer/movieboxpro.app with 428/429.
  static const Map<String, String> movieboxMediaHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; SM-S908B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Referer': 'https://moviebox.ph/',
    'Origin': 'https://moviebox.ph',
    'Accept': '*/*',
    'Accept-Encoding': 'identity',
  };

  // Fallback profiles if CDN rotates header requirements
  static const List<Map<String, String>> fallbackMediaHeaderProfiles = [
    {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Referer': 'https://moviebox.ph/',
      'Origin': 'https://moviebox.ph',
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
    },
    {
      'User-Agent': 'Mozilla/5.0',
      'Referer': 'https://moviebox.ph/',
      'Origin': 'https://moviebox.ph',
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
    },
    {
      'User-Agent': 'MovieBoxPro/16.2.1 (Android 12; Pixel 6)',
      'Referer': 'https://www.movieboxpro.app/',
      'Origin': 'https://www.movieboxpro.app',
      'Accept': '*/*',
    },
    {
      'User-Agent': 'ExoPlayerLib/2.19.1',
      'Referer': 'https://moviebox.ph/',
      'Origin': 'https://moviebox.ph',
      'Accept': '*/*',
    },
  ];

  static const List<Map<String, String>> movieboxMediaHeaderProfiles = [
    movieboxMediaHeaders,
    ...fallbackMediaHeaderProfiles,
  ];

  // Backwards compatibility aliases for previous Zarhosting integration
  static const String zarhostingBaseUrl = movieboxBaseUrl;
  static const Map<String, String> zarhostingApiHeaders = movieboxApiHeaders;
  static const Map<String, String> zarhostingMediaHeaders = movieboxMediaHeaders;
  static const List<Map<String, String>> zarhostingMediaHeaderProfiles =
      movieboxMediaHeaderProfiles;
}
