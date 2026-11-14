import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/constants/api_constants.dart';
import '../models/user_profile.dart';
import '../models/media_item.dart';

class SupabaseService {
  static SupabaseClient? _client;

  static bool get isInitialized => _client != null;
  static SupabaseClient? get client => _client;

  static Future<void> initialize() async {
    try {
      if (ApiConstants.supabaseUrl.isNotEmpty &&
          !ApiConstants.supabaseUrl.contains('placeholder') &&
          ApiConstants.supabaseAnonKey.isNotEmpty &&
          !ApiConstants.supabaseAnonKey.contains('placeholder')) {
        await Supabase.initialize(
          url: ApiConstants.supabaseUrl,
          publishableKey: ApiConstants.supabaseAnonKey,
        );
        _client = Supabase.instance.client;
      }
    } catch (_) {
      // Gracefully fall back to local offline mode
      _client = null;
    }
  }

  // --- Profile Operations ---
  Future<List<UserProfile>> fetchProfiles() async {
    if (_client == null) return [];
    try {
      final user = _client!.auth.currentUser;
      if (user == null) return [];

      final data = await _client!
          .from('profiles')
          .select()
          .eq('user_id', user.id)
          .order('created_at');

      return (data as List).map((p) => UserProfile.fromJson(p)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<UserProfile?> saveProfile(UserProfile profile) async {
    if (_client == null) return null;
    try {
      final user = _client!.auth.currentUser;
      if (user == null) return null;

      final payload = {
        'id': profile.id,
        'user_id': user.id,
        'name': profile.name,
        'avatar_url': profile.avatarUrl,
        'is_kids': profile.isKids,
        'pin_hash': profile.pinHash,
        'language': profile.language,
      };

      final res = await _client!.from('profiles').upsert(payload).select().single();
      return UserProfile.fromJson(res);
    } catch (_) {
      return null;
    }
  }

  Future<bool> deleteProfile(String profileId) async {
    if (_client == null) return false;
    try {
      await _client!.from('profiles').delete().eq('id', profileId);
      return true;
    } catch (_) {
      return false;
    }
  }

  // --- Watch Progress Operations ---
  Future<void> syncWatchProgress({
    required String profileId,
    required MediaItem item,
    required int positionSeconds,
    required int durationSeconds,
    int season = 1,
    int episode = 1,
    String? episodeTitle,
  }) async {
    if (_client == null) return;
    try {
      final user = _client!.auth.currentUser;
      if (user == null) return;

      final isCompleted = durationSeconds > 0 && (positionSeconds / durationSeconds) >= 0.95;

      await _client!.from('watch_progress').upsert({
        'user_id': user.id,
        'profile_id': profileId,
        'tmdb_id': item.id,
        'media_type': item.mediaType,
        'season_number': season,
        'episode_number': episode,
        'episode_title': episodeTitle,
        'title': item.title,
        'poster_path': item.posterPath,
        'backdrop_path': item.backdropPath,
        'position_seconds': positionSeconds,
        'duration_seconds': durationSeconds,
        'completed': isCompleted,
        'last_watched_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {}
  }

  // --- Watchlist Operations ---
  Future<void> syncWatchlistToggle({
    required String profileId,
    required MediaItem item,
    required bool isAdding,
  }) async {
    if (_client == null) return;
    try {
      final user = _client!.auth.currentUser;
      if (user == null) return;

      if (isAdding) {
        await _client!.from('watchlist').upsert({
          'user_id': user.id,
          'profile_id': profileId,
          'tmdb_id': item.id,
          'media_type': item.mediaType,
          'title': item.title,
          'poster_path': item.posterPath,
          'backdrop_path': item.backdropPath,
          'vote_average': item.voteAverage,
          'release_date': item.releaseDate,
          'overview': item.overview,
          'added_at': DateTime.now().toIso8601String(),
        });
      } else {
        await _client!
            .from('watchlist')
            .delete()
            .eq('profile_id', profileId)
            .eq('tmdb_id', item.id)
            .eq('media_type', item.mediaType);
      }
    } catch (_) {}
  }
}
