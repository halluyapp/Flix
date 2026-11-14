import 'package:flutter/foundation.dart';
import '../models/media_item.dart';
import '../models/user_profile.dart';

class WatchProgress {
  final MediaItem item;
  final int season;
  final int episode;
  final int positionSeconds;
  final int durationSeconds;

  WatchProgress({
    required this.item,
    required this.season,
    required this.episode,
    required this.positionSeconds,
    required this.durationSeconds,
  });

  double get progressFraction => durationSeconds > 0
      ? (positionSeconds / durationSeconds).clamp(0.0, 1.0)
      : 0.0;
}

class UserStateService extends ChangeNotifier {
  UserProfile _currentProfile = UserProfile.defaultProfiles.first;
  final List<MediaItem> _myList = [];
  final List<WatchProgress> _continueWatching = [];

  UserProfile get currentProfile => _currentProfile;
  List<MediaItem> get myList => List.unmodifiable(_myList);
  List<WatchProgress> get continueWatching => List.unmodifiable(_continueWatching);

  void setProfile(UserProfile profile) {
    _currentProfile = profile;
    notifyListeners();
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
    notifyListeners();
  }

  void updateProgress({
    required MediaItem item,
    int season = 0,
    int episode = 0,
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
    notifyListeners();
  }
}
