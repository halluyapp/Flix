class MediaItem {
  final int id;
  final String title;
  final String? originalTitle;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final double voteAverage;
  final String releaseDate;
  final String mediaType; // 'movie' or 'tv'
  final List<int> genreIds;

  MediaItem({
    required this.id,
    required this.title,
    this.originalTitle,
    required this.overview,
    this.posterPath,
    this.backdropPath,
    required this.voteAverage,
    required this.releaseDate,
    required this.mediaType,
    required this.genreIds,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json, {String defaultType = 'movie'}) {
    final title = json['title'] ?? json['name'] ?? 'Untitled';
    final releaseDate = json['release_date'] ?? json['first_air_date'] ?? '';
    final mediaType = json['media_type'] ?? defaultType;

    return MediaItem(
      id: json['id'] as int? ?? 0,
      title: title as String,
      originalTitle: (json['original_title'] ?? json['original_name']) as String?,
      overview: (json['overview'] as String?) ?? '',
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0.0,
      releaseDate: releaseDate as String,
      mediaType: mediaType as String,
      genreIds: (json['genre_ids'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList() ??
          [],
    );
  }

  int get releaseYear {
    if (releaseDate.length >= 4) {
      return int.tryParse(releaseDate.substring(0, 4)) ?? 0;
    }
    return 0;
  }

  String get posterUrl => posterPath != null
      ? 'https://image.tmdb.org/t/p/w500$posterPath'
      : 'https://images.unsplash.com/photo-1594909122845-11baa439b7bf?w=500&auto=format&fit=crop&q=60';

  String get backdropUrl => backdropPath != null
      ? 'https://image.tmdb.org/t/p/original$backdropPath'
      : posterUrl;

  int get matchScore => (voteAverage * 10).clamp(65, 99).toInt();
}
