class Episode {
  final int episodeNumber;
  final int seasonNumber;
  final String name;
  final String overview;
  final String? stillPath;
  final double voteAverage;
  final int runtime;

  Episode({
    required this.episodeNumber,
    required this.seasonNumber,
    required this.name,
    required this.overview,
    this.stillPath,
    required this.voteAverage,
    required this.runtime,
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
    );
  }

  String get thumbnail => stillPath != null
      ? 'https://image.tmdb.org/t/p/w500$stillPath'
      : 'https://images.unsplash.com/photo-1594909122845-11baa439b7bf?w=500&auto=format&fit=crop&q=60';
}
