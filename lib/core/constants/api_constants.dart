class ApiConstants {
  // TMDB credentials.
  //
  // These are the repository owner's own credentials, compiled into the app as
  // defaults so CI builds work without extra configuration. The repository is
  // private and this is a read-only TMDB credential.
  //
  // Any build can override them without editing this file:
  //   flutter build apk --release --dart-define=TMDB_READ_TOKEN=...
  static const String tmdbReadToken = String.fromEnvironment(
    'TMDB_READ_TOKEN',
    defaultValue:
        'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJhYzIxZjEwYzQ3M2JhNzZlZGNkODk4M2IxYWUyZWI4OSIsIm5iZiI6MTc2NzYxODIxMi4wNTIsInN1YiI6IjY5NWJiNmE0ZWFlODE5Y2E1NmNiZDNhNiIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.2Aq5ZmRmIU-Qa10uz9IE3b2BW5F-dGc6JyzyRM0iHMA',
  );

  // Fallback v3 key, used only when no read token is present.
  static const String tmdbApiKey = String.fromEnvironment(
    'TMDB_API_KEY',
    defaultValue: 'ac21f10c473ba76edcd8983b1ae2eb89',
  );

  static bool get hasTmdbCredentials => tmdbApiKey.isNotEmpty || tmdbReadToken.isNotEmpty;

  static const String tmdbBaseUrl = 'https://api.themoviedb.org/3';
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
