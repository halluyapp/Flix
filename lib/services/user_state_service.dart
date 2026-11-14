import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_item.dart';
import '../models/user_profile.dart';
import 'supabase_service.dart';

class WatchProgress {
  final MediaItem item;
  final int season;
  final int episode;
  final int positionSeconds;
  final int durationSeconds;
  final DateTime lastWatched;

  WatchProgress({
    required this.item,
    required this.season,
    required this.episode,
    required this.positionSeconds,
    required this.durationSeconds,
    DateTime? lastWatched,
  }) : lastWatched = lastWatched ?? DateTime.now();

  double get progressFraction => durationSeconds > 0
      ? (positionSeconds / durationSeconds).clamp(0.0, 1.0)
      : 0.0;

  Map<String, dynamic> toJson() => {
    'item': {
      'id': item.id,
      'title': item.title,
      'original_title': item.originalTitle,
      'overview': item.overview,
      'poster_path': item.posterPath,
      'backdrop_path': item.backdropPath,
      'vote_average': item.voteAverage,
      'release_date': item.releaseDate,
      'media_type': item.mediaType,
      'genre_ids': item.genreIds,
    },
    'season': season,
    'episode': episode,
    'positionSeconds': positionSeconds,
    'durationSeconds': durationSeconds,
    'lastWatched': lastWatched.toIso8601String(),
  };

  factory WatchProgress.fromJson(Map<String, dynamic> json) {
    return WatchProgress(
      item: MediaItem.fromJson(json['item']),
      season: json['season'] as int? ?? 1,
      episode: json['episode'] as int? ?? 1,
      positionSeconds: json['positionSeconds'] as int? ?? 0,
      durationSeconds: json['durationSeconds'] as int? ?? 0,
      lastWatched: DateTime.tryParse(json['lastWatched'] ?? '') ?? DateTime.now(),
    );
  }
}

class UserStateService extends ChangeNotifier {
  final SupabaseService _supabase = SupabaseService();
  SharedPreferences? _prefs;

  List<UserProfile> _profiles = UserProfile.defaultProfiles;
  UserProfile _currentProfile = UserProfile.defaultProfiles.first;
  final List<MediaItem> _myList = [];
  final List<WatchProgress> _continueWatching = [];

  List<UserProfile> get profiles => List.unmodifiable(_profiles);
  UserProfile get currentProfile => _currentProfile;
  List<MediaItem> get myList => List.unmodifiable(_myList);
  List<WatchProgress> get continueWatching => List.unmodifiable(_continueWatching);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _loadFromLocal();
    _syncWithCloud();
  }

  void _loadFromLocal() {
    if (_prefs == null) return;

    // Load profiles
    final rawProfiles = _prefs!.getString('flix_profiles');
    if (rawProfiles != null) {
      try {
        final list = (json.decode(rawProfiles) as List).map((p) => UserProfile.fromJson(p)).toList();
        if (list.isNotEmpty) _profiles = list;
      } catch (_) {}
    }

    final activeId = _prefs!.getString('flix_active_profile_id');
    _currentProfile = _profiles.firstWhere(
      (p) => p.id == activeId,
      orElse: () => _profiles.first,
    );

    // Load active profile data
    _loadProfileData();
  }

  void _loadProfileData() {
    if (_prefs == null) return;
    final pid = _currentProfile.id;

    // My List
    final rawMyList = _prefs!.getString('flix_my_list_$pid');
    _myList.clear();
    if (rawMyList != null) {
      try {
        final items = (json.decode(rawMyList) as List).map((m) => MediaItem.fromJson(m)).toList();
        _myList.addAll(items);
      } catch (_) {}
    }

    // Continue Watching
    final rawProgress = _prefs!.getString('flix_progress_$pid');
    _continueWatching.clear();
    if (rawProgress != null) {
      try {
        final items = (json.decode(rawProgress) as List).map((w) => WatchProgress.fromJson(w)).toList();
        _continueWatching.addAll(items);
      } catch (_) {}
    }

    notifyListeners();
  }

  Future<void> _saveToLocal() async {
    if (_prefs == null) return;
    final pid = _currentProfile.id;

    await _prefs!.setString(
      'flix_profiles',
      json.encode(_profiles.map((p) => p.toJson()).toList()),
    );
    await _prefs!.setString('flix_active_profile_id', pid);

    await _prefs!.setString(
      'flix_my_list_$pid',
      json.encode(_myList.map((m) => {
        'id': m.id,
        'title': m.title,
        'overview': m.overview,
        'poster_path': m.posterPath,
        'backdrop_path': m.backdropPath,
        'vote_average': m.voteAverage,
        'release_date': m.releaseDate,
        'media_type': m.mediaType,
        'genre_ids': m.genreIds,
      }).toList()),
    );

    await _prefs!.setString(
      'flix_progress_$pid',
      json.encode(_continueWatching.map((w) => w.toJson()).toList()),
    );
  }

  Future<void> _syncWithCloud() async {
    try {
      final cloudProfiles = await _supabase.fetchProfiles();
      if (cloudProfiles.isNotEmpty) {
        _profiles = cloudProfiles;
        _saveToLocal();
        notifyListeners();
      }
    } catch (_) {}
  }

  void setProfile(UserProfile profile) {
    _currentProfile = profile;
    _prefs?.setString('flix_active_profile_id', profile.id);
    _loadProfileData();
  }

  Future<bool> addProfile({
    required String name,
    required String avatarUrl,
    bool isKids = false,
    String? pin,
  }) async {
    if (_profiles.length >= 5) return false;

    final newProfile = UserProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      avatarUrl: avatarUrl,
      isKids: isKids,
      pinHash: pin != null && pin.isNotEmpty ? UserProfile.hashPin(pin) : null,
    );

    _profiles.add(newProfile);
    await _saveToLocal();
    _supabase.saveProfile(newProfile);
    notifyListeners();
    return true;
  }

  Future<void> deleteProfile(String profileId) async {
    if (_profiles.length <= 1) return;
    _profiles.removeWhere((p) => p.id == profileId);
    if (_currentProfile.id == profileId) {
      _currentProfile = _profiles.first;
    }
    await _saveToLocal();
    _supabase.deleteProfile(profileId);
    _loadProfileData();
  }

  bool isInMyList(MediaItem item) {
    return _myList.any((m) => m.id == item.id && m.mediaType == item.mediaType);
  }

  void toggleMyList(MediaItem item) {
    final adding = !isInMyList(item);
    if (adding) {
      _myList.insert(0, item);
    } else {
      _myList.removeWhere((m) => m.id == item.id && m.mediaType == item.mediaType);
    }
    _saveToLocal();
    _supabase.syncWatchlistToggle(
      profileId: _currentProfile.id,
      item: item,
      isAdding: adding,
    );
    notifyListeners();
  }

  void updateProgress({
    required MediaItem item,
    int season = 1,
    int episode = 1,
    String? episodeTitle,
    required int positionSeconds,
    required int durationSeconds,
  }) {
    _continueWatching.removeWhere((w) => w.item.id == item.id);
    _continueWatching.insert(
      0,
      WatchProgress(
        item: item,
        season: season,
        episode: episode,
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
      ),
    );
    _saveToLocal();
    _supabase.syncWatchProgress(
      profileId: _currentProfile.id,
      item: item,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
    );
    notifyListeners();
  }
}
