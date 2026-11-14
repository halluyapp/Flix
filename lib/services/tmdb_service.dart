import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants/api_constants.dart';
import '../models/media_item.dart';
import '../models/episode.dart';

class TmdbService {
  final Map<String, String> _headers = {
    'Authorization': 'Bearer ${ApiConstants.tmdbReadToken}',
    'Accept': 'application/json',
  };

  Future<List<MediaItem>> getTrending({String timeWindow = 'day'}) async {
    final url = Uri.parse('${ApiConstants.tmdbBaseUrl}/trending/all/$timeWindow');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      final List results = data['results'] ?? [];
      return results
          .where((item) => item['media_type'] == 'movie' || item['media_type'] == 'tv')
          .map((item) => MediaItem.fromJson(item))
          .toList();
    }
    return [];
  }

  Future<List<MediaItem>> getTopRated({String type = 'movie'}) async {
    final url = Uri.parse('${ApiConstants.tmdbBaseUrl}/$type/top_rated');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      final List results = data['results'] ?? [];
      return results.map((item) => MediaItem.fromJson(item, defaultType: type)).toList();
    }
    return [];
  }

  Future<List<MediaItem>> getPopularMovies() async {
    final url = Uri.parse('${ApiConstants.tmdbBaseUrl}/movie/popular');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      final List results = data['results'] ?? [];
      return results.map((item) => MediaItem.fromJson(item, defaultType: 'movie')).toList();
    }
    return [];
  }

  Future<List<MediaItem>> getPopularTv() async {
    final url = Uri.parse('${ApiConstants.tmdbBaseUrl}/tv/popular');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      final List results = data['results'] ?? [];
      return results.map((item) => MediaItem.fromJson(item, defaultType: 'tv')).toList();
    }
    return [];
  }

  Future<List<MediaItem>> getByGenre(int genreId, {bool isTv = false}) async {
    final endpoint = isTv ? 'discover/tv' : 'discover/movie';
    final url = Uri.parse('${ApiConstants.tmdbBaseUrl}/$endpoint?with_genres=$genreId&sort_by=popularity.desc');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      final List results = data['results'] ?? [];
      return results.map((item) => MediaItem.fromJson(item, defaultType: isTv ? 'tv' : 'movie')).toList();
    }
    return [];
  }

  Future<List<Episode>> getSeasonEpisodes(int tvId, int seasonNumber) async {
    final url = Uri.parse('${ApiConstants.tmdbBaseUrl}/tv/$tvId/season/$seasonNumber');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      final List episodes = data['episodes'] ?? [];
      return episodes.map((e) => Episode.fromJson(e)).toList();
    }
    return [];
  }

  Future<List<MediaItem>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final url = Uri.parse('${ApiConstants.tmdbBaseUrl}/search/multi?query=${Uri.encodeComponent(query)}');
    final res = await http.get(url, headers: _headers);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      final List results = data['results'] ?? [];
      return results
          .where((item) => item['media_type'] == 'movie' || item['media_type'] == 'tv')
          .map((item) => MediaItem.fromJson(item))
          .toList();
    }
    return [];
  }
}
