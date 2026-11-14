class MediaItem {
  final int id;
  final String title;
  final String? originalTitle;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final String? posterUrlOverride;
  final String? backdropUrlOverride;
  final String? providerSubjectId;
  final String? providerDetailPath;
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
    this.posterUrlOverride,
    this.backdropUrlOverride,
    this.providerSubjectId,
    this.providerDetailPath,
    required this.voteAverage,
    required this.releaseDate,
    required this.mediaType,
    required this.genreIds,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json,
      {String defaultType = 'movie'}) {
    final title = json['title'] ?? json['name'] ?? 'Untitled';
    final releaseDate = json['release_date'] ?? json['first_air_date'] ?? '';
    final mediaType = json['media_type'] ?? defaultType;

    return MediaItem(
      id: json['id'] as int? ?? 0,
      title: title as String,
      originalTitle:
          (json['original_title'] ?? json['original_name']) as String?,
      overview: (json['overview'] as String?) ?? '',
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      posterUrlOverride: json['poster_url_override'] as String?,
      backdropUrlOverride: json['backdrop_url_override'] as String?,
      providerSubjectId: json['provider_subject_id'] as String?,
      providerDetailPath: json['provider_detail_path'] as String?,
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

  String get posterUrl =>
      posterUrlOverride ??
      (posterPath != null
          ? 'https://image.tmdb.org/t/p/w500$posterPath'
          : 'https://images.unsplash.com/photo-1594909122845-11baa439b7bf?w=500&auto=format&fit=crop&q=60');

  String get backdropUrl =>
      backdropUrlOverride ??
      (backdropPath != null
          ? 'https://image.tmdb.org/t/p/original$backdropPath'
          : posterUrl);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'original_title': originalTitle,
        'overview': overview,
        'poster_path': posterPath,
        'backdrop_path': backdropPath,
        'poster_url_override': posterUrlOverride,
        'backdrop_url_override': backdropUrlOverride,
        'provider_subject_id': providerSubjectId,
        'provider_detail_path': providerDetailPath,
        'vote_average': voteAverage,
        'release_date': releaseDate,
        'media_type': mediaType,
        'genre_ids': genreIds,
      };

  int get matchScore => (voteAverage * 10).clamp(65, 99).toInt();
}
