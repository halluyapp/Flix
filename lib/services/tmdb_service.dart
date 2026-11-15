import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants/api_constants.dart';
import '../models/media_item.dart';
import '../models/episode.dart';
import '../models/tv_season.dart';

class TmdbService {
  final http.Client? _client;
  bool _hasSuccessfulSupabaseResponse = false;

  TmdbService({http.Client? client}) : _client = client;

  /// True after a valid HTTP 200 JSON response from Flix's Supabase Edge Function.
  bool get hasSuccessfulSupabaseResponse => _hasSuccessfulSupabaseResponse;

  /// Starts a fresh connection check for the next group of catalogue requests.
  void resetSupabaseConnectionStatus() {
    _hasSuccessfulSupabaseResponse = false;
  }

  /// Calls Flix's server-side TMDB proxy. The TMDB bearer token is never
  /// embedded in or sent by the mobile client.
  Future<dynamic> _fetchTmdb(String path, [Map<String, String>? queryParams]) async {
    if (ApiConstants.supabaseUrl.isEmpty) return null;

    try {
      final query = Map<String, String>.from(queryParams ?? const <String, String>{});
      query['path'] = path;
      final uri = Uri.parse(ApiConstants.tmdbProxyUrl).replace(queryParameters: query);
      const headers = {'Accept': 'application/json'};
      final client = _client;
      final request = client == null
          ? http.get(uri, headers: headers)
          : client.get(uri, headers: headers);
      final response = await request.timeout(const Duration(seconds: 12));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        _hasSuccessfulSupabaseResponse = true;
        return decoded;
      }
    } catch (_) {
      // Network failure or malformed response is rendered as an empty state.
    }

    return null;
  }

  List<MediaItem> _mapResults(dynamic data, String type) {
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .whereType<Map>()
          .map((item) => MediaItem.fromJson(Map<String, dynamic>.from(item), defaultType: type))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getTrending({String timeWindow = 'day'}) async {
    final data = await _fetchTmdb('/trending/all/$timeWindow');
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .whereType<Map>()
          .where((item) => item['media_type'] == 'movie' || item['media_type'] == 'tv')
          .map((item) => MediaItem.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getTop10Today() async {
    final trending = await getTrending(timeWindow: 'day');
    return trending.take(10).toList();
  }

  Future<List<MediaItem>> getTopRated({String type = 'movie'}) async {
    return _mapResults(await _fetchTmdb('/$type/top_rated'), type);
  }

  Future<List<MediaItem>> getPopularMovies() async {
    return _mapResults(await _fetchTmdb('/movie/popular'), 'movie');
  }

  Future<List<MediaItem>> getPopularTv() async {
    return _mapResults(await _fetchTmdb('/tv/popular'), 'tv');
  }

  Future<List<MediaItem>> getKdramas() async {
    return _mapResults(
      await _fetchTmdb('/discover/tv', {
        'with_original_language': 'ko',
        'sort_by': 'popularity.desc',
      }),
      'tv',
    );
  }

  Future<List<MediaItem>> getNollywood() async {
    return _mapResults(
      await _fetchTmdb('/discover/movie', {
        'with_origin_country': 'NG',
        'sort_by': 'popularity.desc',
      }),
      'movie',
    );
  }

  Future<List<MediaItem>> getAnime() async {
    return _mapResults(
      await _fetchTmdb('/discover/tv', {
        'with_genres': '16',
        'with_original_language': 'ja',
        'sort_by': 'popularity.desc',
      }),
      'tv',
    );
  }

  Future<List<MediaItem>> getByGenre(int genreId, {bool isTv = false}) async {
    final endpoint = isTv ? '/discover/tv' : '/discover/movie';
    return _mapResults(
      await _fetchTmdb(endpoint, {
        'with_genres': genreId.toString(),
        'sort_by': 'popularity.desc',
      }),
      isTv ? 'tv' : 'movie',
    );
  }

  /// Real season list from TMDB. Never hardcodes a season count.
  /// If the direct /tv/{id} endpoint is rejected by the catalogue proxy,
  /// it discovers seasons 1..10 in parallel via the supported
  /// /tv/{id}/season/{s} route so Season 2, Season 3, etc. are visible.
  Future<List<TvSeason>> getSeasons(int tvId) async {
    final data = await _fetchTmdb('/tv/$tvId');
    if (data is Map && data['seasons'] is List) {
      final list = (data['seasons'] as List)
          .whereType<Map>()
          .map((entry) => TvSeason.fromJson(Map<String, dynamic>.from(entry)))
          .where((s) => s.hasEpisodes || s.seasonNumber > 0)
          .toList(growable: false);
      if (list.isNotEmpty) return list;
    }

    final probes = await Future.wait([
      for (int s = 1; s <= 10; s++) _fetchTmdb('/tv/$tvId/season/$s'),
    ]);

    final List<TvSeason> discovered = [];
    for (int i = 0; i < probes.length; i++) {
      final seasonNum = i + 1;
      final res = probes[i];
      if (res is Map) {
        final eps = res['episodes'] as List? ?? [];
        final name = (res['name'] ?? 'Season $seasonNum').toString();
        final airDate = (res['air_date'] ?? '').toString();
        discovered.add(TvSeason(
          seasonNumber: seasonNum,
          name: name,
          episodeCount: eps.length,
          airDate: airDate,
        ));
      }
    }
    return discovered;
  }

  Future<List<Episode>> getSeasonEpisodes(int tvId, int seasonNumber) async {
    final data = await _fetchTmdb('/tv/$tvId/season/$seasonNumber');
    if (data is Map && data['episodes'] is List) {
      return (data['episodes'] as List)
          .whereType<Map>()
          .map((e) => Episode.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getUpcoming() async {
    return _mapResults(await _fetchTmdb('/movie/upcoming'), 'movie');
  }

  Future<List<MediaItem>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final data = await _fetchTmdb('/search/multi', {'query': query.trim()});
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .whereType<Map>()
          .where((item) => item['media_type'] == 'movie' || item['media_type'] == 'tv')
          .map((item) => MediaItem.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    }
    return [];
  }
}
