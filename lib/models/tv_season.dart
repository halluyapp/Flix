class TvSeason {
  final int seasonNumber;
  final String name;
  final int episodeCount;
  final String? posterPath;
  final String airDate;

  const TvSeason({
    required this.seasonNumber,
    required this.name,
    required this.episodeCount,
    this.posterPath,
    this.airDate = '',
  });

  factory TvSeason.fromJson(Map<String, dynamic> json) => TvSeason(
        seasonNumber: (json['season_number'] as num?)?.toInt() ?? 0,
        name: (json['name'] ?? '').toString(),
        episodeCount: (json['episode_count'] as num?)?.toInt() ?? 0,
        posterPath: json['poster_path'] as String?,
        airDate: (json['air_date'] ?? '').toString(),
      );

  String get label {
    if (seasonNumber == 0) return 'Specials';
    if (name.trim().isNotEmpty && name.trim().toLowerCase() != 'season $seasonNumber') {
      return name.trim();
    }
    return 'Season $seasonNumber';
  }

  String? get posterUrl => posterPath == null
      ? null
      : 'https://image.tmdb.org/t/p/w342$posterPath';

  bool get hasEpisodes => episodeCount > 0;
}
