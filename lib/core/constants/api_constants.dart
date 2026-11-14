class ApiConstants {
  // TMDB Credentials
  static const String tmdbApiKey = 'ac21f10c473ba76edcd8983b1ae2eb89';
  static const String tmdbReadToken =
      'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJhYzIxZjEwYzQ3M2JhNzZlZGNkODk4M2IxYWUyZWI4OSIsIm5iZiI6MTc2NzYxODIxMi4wNTIsInN1YiI6IjY5NWJiNmE0ZWFlODE5Y2E1NmNiZDNhNiIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.2Aq5ZmRmIU-Qa10uz9IE3b2BW5F-dGc6JyzyRM0iHMA';

  static const String tmdbBaseUrl = 'https://api.themoviedb.org/3';
  static const String tmdbImageBaseW500 = 'https://image.tmdb.org/t/p/w500';
  static const String tmdbImageBaseOriginal = 'https://image.tmdb.org/t/p/original';

  // Zarhosting Provider Endpoints
  static const String zarhostingBaseUrl = 'https://movieapi.zarhosting.dpdns.org/api/public/v1';

  static const Map<String, String> zarhostingApiHeaders = {
    'User-Agent': 'Mozilla/5.0',
    'Referer': 'https://moviebox.ph/',
    'Accept': 'application/json',
  };

  // ExoPlayer CDN profile required for playback
  static const Map<String, String> zarhostingMediaHeaders = {
    'User-Agent': 'ExoPlayerLib/2.19.1',
    'Referer': 'https://www.movieboxpro.app/',
    'Origin': 'https://www.movieboxpro.app',
    'Accept': '*/*',
    'Accept-Encoding': 'identity',
  };
}
