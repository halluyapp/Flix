/// A season/episode pointer, independent of TMDB models so the navigation rules
/// can be unit-tested without a network call.
class EpisodePointer {
  final int season;
  final int episode;

  const EpisodePointer(this.season, this.episode);

  @override
  bool operator ==(Object other) =>
      other is EpisodePointer &&
      other.season == season &&
      other.episode == episode;

  @override
  int get hashCode => Object.hash(season, episode);

  @override
  String toString() => 'S${season}E$episode';
}

/// Season-boundary aware next-episode rules.
///
/// Uses the seasons and episode numbers TMDB actually returned; nothing is
/// hardcoded, and missing seasons or specials are skipped rather than invented.
class EpisodeNavigator {
  const EpisodeNavigator._();

  static EpisodePointer? next({
    required int currentSeason,
    required int currentEpisode,
    required Map<int, List<int>> episodesBySeason,
    List<int>? seasonOrder,
  }) {
    final seasons = seasonOrder != null && seasonOrder.isNotEmpty
        ? List<int>.from(seasonOrder)
        : (episodesBySeason.keys.toList()..sort());
    if (seasons.isEmpty) return null;

    final currentEpisodes = _sorted(episodesBySeason[currentSeason]);
    if (currentEpisodes.isNotEmpty) {
      for (final candidate in currentEpisodes) {
        if (candidate > currentEpisode) {
          return EpisodePointer(currentSeason, candidate);
        }
      }
    }

    // Move to the first episode of the next available season that actually has
    // episode data.
    var foundCurrent = episodesBySeason.containsKey(currentSeason);
    for (final season in seasons) {
      if (season == currentSeason) {
        foundCurrent = true;
        continue;
      }
      if (!foundCurrent) continue;
      if (season < currentSeason) continue;
      final episodes = _sorted(episodesBySeason[season]);
      if (episodes.isEmpty) continue;
      return EpisodePointer(season, episodes.first);
    }
    return null;
  }

  static EpisodePointer? previous({
    required int currentSeason,
    required int currentEpisode,
    required Map<int, List<int>> episodesBySeason,
  }) {
    final seasons = episodesBySeason.keys.toList()..sort();
    final currentEpisodes = _sorted(episodesBySeason[currentSeason]);
    for (final candidate in currentEpisodes.reversed) {
      if (candidate < currentEpisode) {
        return EpisodePointer(currentSeason, candidate);
      }
    }
    for (var index = seasons.length - 1; index >= 0; index--) {
      final season = seasons[index];
      if (season >= currentSeason) continue;
      final episodes = _sorted(episodesBySeason[season]);
      if (episodes.isEmpty) continue;
      return EpisodePointer(season, episodes.last);
    }
    return null;
  }

  static List<int> _sorted(List<int>? values) {
    if (values == null || values.isEmpty) return const [];
    final sorted = List<int>.from(values)..sort();
    return sorted;
  }
}
