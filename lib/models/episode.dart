class Episode {
  final int episodeNumber;
  final int seasonNumber;
  final String name;
  final String overview;
  final String? stillPath;
  final double voteAverage;
  final int runtime;
  final String airDate;

  Episode({
    required this.episodeNumber,
    required this.seasonNumber,
    required this.name,
    required this.overview,
    this.stillPath,
    required this.voteAverage,
    required this.runtime,
    this.airDate = '',
  });

  factory Episode.fromJson(Map<String, dynamic> json) {
    return Episode(
      episodeNumber: json['episode_number'] as int? ?? 1,
      seasonNumber: json['season_number'] as int? ?? 1,
      name: (json['name'] as String?) ?? 'Episode ${json['episode_number'] ?? 1}',
      overview: (json['overview'] as String?) ?? '',
      stillPath: json['still_path'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0.0,
      runtime: (json['runtime'] as int?) ?? 45,
      airDate: (json['air_date'] ?? '').toString(),
    );
  }

  /// Whether this episode has officially aired. Future episodes scheduled on TMDB
  /// are not yet playable or downloadable from media providers.
  bool get isReleased {
    if (airDate.trim().isEmpty) return true;
    try {
      final air = DateTime.parse(airDate.trim());
      final now = DateTime.now();
      return !air.isAfter(now);
    } catch (_) {
      return true;
    }
  }

  /// A friendly release badge for upcoming episodes, e.g. "Coming Nov 21".
  String get releaseBadge {
    if (isReleased || airDate.trim().isEmpty) return '';
    try {
      final air = DateTime.parse(airDate.trim());
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return 'Coming ${months[air.month - 1]} ${air.day}';
    } catch (_) {
      return 'Coming Soon';
    }
  }

  String get thumbnail => stillPath != null
      ? 'https://image.tmdb.org/t/p/w500$stillPath'
      : 'https://images.unsplash.com/photo-1594909122845-11baa439b7bf?w=500&auto=format&fit=crop&q=60';
}
