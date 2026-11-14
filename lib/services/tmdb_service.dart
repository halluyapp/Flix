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

  Future<dynamic> _fetchTmdb(String path, [Map<String, String>? queryParams]) async {
    // 1. Try Cloud Edge Proxy first (keeps TMDB secrets server-side)
    if (ApiConstants.tmdbProxyUrl.isNotEmpty &&
        !ApiConstants.tmdbProxyUrl.contains('placeholder')) {
      try {
        final query = Map<String, String>.from(queryParams ?? {});
        query['path'] = path;
        final proxyUri = Uri.parse(ApiConstants.tmdbProxyUrl).replace(queryParameters: query);
        final res = await http.get(proxyUri).timeout(const Duration(seconds: 12));
        if (res.statusCode == 200) {
          return json.decode(res.body);
        }
      } catch (_) {}
    }

    // 2. Direct TMDB fallback
    try {
      final query = Map<String, String>.from(queryParams ?? {});
      if (ApiConstants.tmdbApiKey.isNotEmpty && !query.containsKey('api_key')) {
        query['api_key'] = ApiConstants.tmdbApiKey;
      }
      final uri = Uri.parse('${ApiConstants.tmdbBaseUrl}$path').replace(queryParameters: query);
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        return json.decode(res.body);
      }
    } catch (_) {}

    return null;
  }

  Future<List<MediaItem>> getTrending({String timeWindow = 'day'}) async {
    final data = await _fetchTmdb('/trending/all/$timeWindow');
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .where((item) => item['media_type'] == 'movie' || item['media_type'] == 'tv')
          .map((item) => MediaItem.fromJson(item))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getTop10Today() async {
    final trending = await getTrending(timeWindow: 'day');
    return trending.take(10).toList();
  }

  Future<List<MediaItem>> getTopRated({String type = 'movie'}) async {
    final data = await _fetchTmdb('/$type/top_rated');
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .map((item) => MediaItem.fromJson(item, defaultType: type))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getPopularMovies() async {
    final data = await _fetchTmdb('/movie/popular');
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .map((item) => MediaItem.fromJson(item, defaultType: 'movie'))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getPopularTv() async {
    final data = await _fetchTmdb('/tv/popular');
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .map((item) => MediaItem.fromJson(item, defaultType: 'tv'))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getKdramas() async {
    final data = await _fetchTmdb('/discover/tv', {
      'with_original_language': 'ko',
      'sort_by': 'popularity.desc',
    });
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .map((item) => MediaItem.fromJson(item, defaultType: 'tv'))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getNollywood() async {
    final data = await _fetchTmdb('/discover/movie', {
      'with_origin_country': 'NG',
      'sort_by': 'popularity.desc',
    });
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .map((item) => MediaItem.fromJson(item, defaultType: 'movie'))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getAnime() async {
    final data = await _fetchTmdb('/discover/tv', {
      'with_genres': '16',
      'with_original_language': 'ja',
      'sort_by': 'popularity.desc',
    });
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .map((item) => MediaItem.fromJson(item, defaultType: 'tv'))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getByGenre(int genreId, {bool isTv = false}) async {
    final endpoint = isTv ? '/discover/tv' : '/discover/movie';
    final data = await _fetchTmdb(endpoint, {
      'with_genres': genreId.toString(),
      'sort_by': 'popularity.desc',
    });
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .map((item) => MediaItem.fromJson(item, defaultType: isTv ? 'tv' : 'movie'))
          .toList();
    }
    return [];
  }

  Future<List<Episode>> getSeasonEpisodes(int tvId, int seasonNumber) async {
    final data = await _fetchTmdb('/tv/$tvId/season/$seasonNumber');
    if (data is Map && data['episodes'] is List) {
      return (data['episodes'] as List)
          .map((e) => Episode.fromJson(e))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getUpcoming() async {
    final data = await _fetchTmdb('/movie/upcoming');
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .map((item) => MediaItem.fromJson(item, defaultType: 'movie'))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final data = await _fetchTmdb('/search/multi', {'query': query.trim()});
    if (data is Map && data['results'] is List) {
      return (data['results'] as List)
          .where((item) => item['media_type'] == 'movie' || item['media_type'] == 'tv')
          .map((item) => MediaItem.fromJson(item))
          .toList();
    }
    return [];
  }
}
