import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_item.dart';
import '../models/user_profile.dart';

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

  bool get isCompleted => progressFraction >= 0.95;

  Map<String, dynamic> toJson() => {
    'item': {
      'id': item.id,
      'title': item.title,
      'original_title': item.originalTitle,
      'overview': item.overview,
      'poster_path': item.posterPath,
      'backdrop_path': item.backdropPath,
      'poster_url_override': item.posterUrlOverride,
      'backdrop_url_override': item.backdropUrlOverride,
      'provider_subject_id': item.providerSubjectId,
      'provider_detail_path': item.providerDetailPath,
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
      item: MediaItem.fromJson(Map<String, dynamic>.from(json['item'] as Map)),
      season: json['season'] as int? ?? 1,
      episode: json['episode'] as int? ?? 1,
      positionSeconds: json['positionSeconds'] as int? ?? 0,
      durationSeconds: json['durationSeconds'] as int? ?? 0,
      lastWatched: DateTime.tryParse(json['lastWatched']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

/// All viewer state (profiles, My List, watch progress) lives in local storage.
/// No backend is contacted; every mutation is written straight to
/// SharedPreferences and the in-memory lists.
class UserStateService extends ChangeNotifier {
  static const int maxProfiles = 5;

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
    try {
      _prefs = await SharedPreferences.getInstance();
      _loadFromLocal();
    } catch (error, stackTrace) {
      debugPrint('Flix startup: local preferences unavailable: $error\n$stackTrace');
      // Keep the default in-memory profile so a storage/plugin issue cannot
      // prevent the app from reaching its first screen.
      _prefs = null;
    }
  }

  void _loadFromLocal() {
    final prefs = _prefs;
    if (prefs == null) return;

    final rawProfiles = prefs.getString('flix_profiles');
    if (rawProfiles != null) {
      try {
        final list = (json.decode(rawProfiles) as List)
            .map((p) => UserProfile.fromJson(Map<String, dynamic>.from(p as Map)))
            .toList();
        if (list.isNotEmpty) _profiles = list;
      } catch (_) {
        _profiles = UserProfile.defaultProfiles;
      }
    }

    final activeId = prefs.getString('flix_active_profile_id');
    _currentProfile = _profiles.firstWhere(
      (p) => p.id == activeId,
      orElse: () => _profiles.first,
    );

    _loadProfileData();
  }

  void _loadProfileData() {
    final prefs = _prefs;
    if (prefs == null) return;
    final pid = _currentProfile.id;

    final rawMyList = prefs.getString('flix_my_list_$pid');
    _myList.clear();
    if (rawMyList != null) {
      try {
        _myList.addAll((json.decode(rawMyList) as List)
            .map((m) => MediaItem.fromJson(Map<String, dynamic>.from(m as Map))));
      } catch (_) {}
    }

    final rawProgress = prefs.getString('flix_progress_$pid');
    _continueWatching.clear();
    if (rawProgress != null) {
      try {
        _continueWatching.addAll((json.decode(rawProgress) as List)
            .map((w) => WatchProgress.fromJson(Map<String, dynamic>.from(w as Map))));
      } catch (_) {}
    }

    notifyListeners();
  }

  /// Saves run through a single chain so an older asynchronous snapshot can
  /// never land after a newer one. Snapshots are captured at call time.
  Future<void> _saveChain = Future<void>.value();

  Future<void> _saveToLocal() {
    final prefs = _prefs;
    if (prefs == null) return Future<void>.value();
    final pid = _currentProfile.id;
    final profilesJson =
        json.encode(_profiles.map((profile) => profile.toJson()).toList());
    final myListJson =
        json.encode(_myList.map((item) => item.toJson()).toList());
    final progressJson = json.encode(
      _continueWatching.map((entry) => entry.toJson()).toList(),
    );

    _saveChain = _saveChain.then((_) async {
      try {
        await prefs.setString('flix_profiles', profilesJson);
        await prefs.setString('flix_active_profile_id', pid);
        await prefs.setString('flix_my_list_$pid', myListJson);
        await prefs.setString('flix_progress_$pid', progressJson);
      } catch (error) {
        debugPrint('Flix could not persist profile state: $error');
      }
    });
    return _saveChain;
  }

  void setProfile(UserProfile profile) {
    _currentProfile = profile;
    _prefs?.setString('flix_active_profile_id', profile.id);
    _loadProfileData();
  }

  bool get canAddProfile => _profiles.length < maxProfiles;

  Future<bool> addProfile({
    required String name,
    required String avatarUrl,
    bool isKids = false,
    String? pin,
  }) async {
    if (!canAddProfile) return false;

    final newProfile = UserProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      avatarUrl: avatarUrl,
      isKids: isKids,
      pinHash: pin != null && pin.isNotEmpty ? UserProfile.hashPin(pin) : null,
    );

    _profiles.add(newProfile);
    await _saveToLocal();
    notifyListeners();
    return true;
  }

  Future<void> deleteProfile(String profileId) async {
    if (_profiles.length <= 1) return;
    final wasActive = _currentProfile.id == profileId;
    _profiles.removeWhere((p) => p.id == profileId);
    if (wasActive) _currentProfile = _profiles.first;
    await _saveToLocal();
    if (wasActive) {
      _loadProfileData();
    } else {
      notifyListeners();
    }
  }

  bool isInMyList(MediaItem item) {
    return _myList.any((m) => m.id == item.id && m.mediaType == item.mediaType);
  }

  void toggleMyList(MediaItem item) {
    if (isInMyList(item)) {
      _myList.removeWhere((m) => m.id == item.id && m.mediaType == item.mediaType);
    } else {
      _myList.insert(0, item);
    }
    _saveToLocal();
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
    _continueWatching.removeWhere(
      (w) => w.item.id == item.id && w.season == season && w.episode == episode,
    );
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
    notifyListeners();
  }

  WatchProgress? progressFor(MediaItem item, {int season = 1, int episode = 1}) {
    for (final w in _continueWatching) {
      if (w.item.id == item.id && w.item.mediaType == item.mediaType) {
        if (item.mediaType == 'tv' && (w.season != season || w.episode != episode)) {
          continue;
        }
        return w;
      }
    }
    return null;
  }
}
