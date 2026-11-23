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

  // MovieBox Official H5 Media Provider Endpoints
  // Base upstream BFF serving catalogue search, stream resolution, and captions.
  static const String movieboxH5BaseUrl =
      'https://h5-api.aoneroom.com/wefeed-h5api-bff';
  static const String movieboxAltBaseUrl =
      'https://mzfi.me/wefeed-h5api-bff';

  // Backwards compatibility alias
  static const String zarhostingBaseUrl = movieboxH5BaseUrl;

  static const String movieboxHost = 'moviebox.ph';
  static const String movieboxOrigin = 'https://mzfi.me';
  static const String movieboxRefererBase =
      'https://mzfi.me/spa/videoPlayPage/movies/';

  // Provider API headers required by the MovieBox BFF
  static const Map<String, String> movieboxApiHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Origin': 'https://mzfi.me',
    'Referer': 'https://moviebox.ph/',
    'Accept': 'application/json',
    'X-Client-Info': '{"timezone":"Africa/Lagos"}',
    'X-Vip-Restrict': '0',
  };

  // Backwards compatibility alias
  static const Map<String, String> zarhostingApiHeaders = movieboxApiHeaders;

  // Primary verified media & streaming headers required by MovieBox / hakunaymatata CDN.
  // The CDN strictly requires Referer: https://mzfi.me/ and returns 200/206 Partial Content.
  static const Map<String, String> movieboxMediaHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Referer': 'https://mzfi.me/',
    'Origin': 'https://mzfi.me',
    'Accept': '*/*',
  };

  // Backwards compatibility alias
  static const Map<String, String> zarhostingMediaHeaders = movieboxMediaHeaders;

  // Fallback profiles if CDN rotates header requirements
  static const List<Map<String, String>> fallbackMediaHeaderProfiles = [
    {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; SM-S908B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Referer': 'https://mzfi.me/',
      'Origin': 'https://mzfi.me',
      'Accept': '*/*',
    },
    {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Referer': 'https://moviebox.ph/',
      'Origin': 'https://moviebox.ph',
      'Accept': '*/*',
    },
    {
      'User-Agent': 'Mozilla/5.0',
      'Referer': 'https://mzfi.me/',
      'Origin': 'https://mzfi.me',
      'Accept': '*/*',
    },
  ];

  static const List<Map<String, String>> zarhostingMediaHeaderProfiles = [
    movieboxMediaHeaders,
    ...fallbackMediaHeaderProfiles,
  ];
}
