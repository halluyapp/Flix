import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants/api_constants.dart';
import '../models/media_item.dart';
import '../models/episode.dart';

class TmdbService {
  Map<String, String> get _headers {
    final h = {'Accept': 'application/json'};
    if (ApiConstants.tmdbReadToken.isNotEmpty) {
      h['Authorization'] = 'Bearer ${ApiConstants.tmdbReadToken}';
    }
    return h;
  }

  /// Calls TMDB directly. Returns null when no credentials are configured or
  /// the request fails, so callers can render an empty state.
  Future<dynamic> _fetchTmdb(String path, [Map<String, String>? queryParams]) async {
    if (!ApiConstants.hasTmdbCredentials) return null;

    try {
      final query = Map<String, String>.from(queryParams ?? {});
      // Send exactly one credential: the bearer token when present, otherwise
      // the v3 API key.
      if (ApiConstants.tmdbReadToken.isEmpty &&
          ApiConstants.tmdbApiKey.isNotEmpty &&
          !query.containsKey('api_key')) {
        query['api_key'] = ApiConstants.tmdbApiKey;
      }
      final uri = Uri.parse('${ApiConstants.tmdbBaseUrl}$path').replace(queryParameters: query);
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        return json.decode(res.body);
      }
    } catch (_) {
      // Network failure or malformed response: reported as "no data".
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
