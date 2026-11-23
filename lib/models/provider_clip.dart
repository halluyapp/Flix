import 'media_item.dart';
import '../services/provider_payload.dart';

/// A short movie returned by the media provider's catalogue search.
///
/// Clips are accepted only when the provider explicitly marks the item as a
/// movie, includes the exact "Short" genre, and reports a playable resource.
/// A text match such as a title containing "short" is never sufficient.
class ProviderClip {
  final String subjectId;
  final String detailPath;
  final String title;
  final String posterUrl;
  final String genre;
  final String country;
  final String description;
  final int year;
  final double rating;

  const ProviderClip({
    required this.subjectId,
    required this.detailPath,
    required this.title,
    required this.posterUrl,
    required this.genre,
    required this.country,
    required this.description,
    required this.year,
    required this.rating,
  });

  static const Set<String> _shortGenreNames = {
    'short',
    'shorts',
    'short film',
    'short films',
  };

  static const Set<String> _adultGenres = {
    'adult',
    'erotic',
    'hot',
    'porn',
    'xxx',
    'sexual',
    'hentai',
    'nsfw',
    '18+',
    '18 plus',
    'r18',
    'r-18',
    'nc-17',
  };

  static final RegExp _adultRating = RegExp(
    r'^(?:18(?:\+| plus)?|r-?18|nc-?17|xxx|adult(?:s)?(?: only)?)$',
    caseSensitive: false,
  );

  static final RegExp _explicitTitle = RegExp(
    r'\b(?:porn|xxx|erotic|hentai|milf|orgy|nude|fuck(?:ed|ing|s)?)\b',
    caseSensitive: false,
  );

  static bool _isAffirmative(Object? input) {
    if (input == true || input == 1) return true;
    final normalized = input?.toString().trim().toLowerCase();
    return const {'true', 'yes', '1', 'adult', 'nsfw'}.contains(normalized);
  }

  static bool _isAdultRecord(Map<String, dynamic> json) {
    const flagKeys = [
      'adult',
      'is_adult',
      'isAdult',
      'adult_content',
      'explicit',
      'nsfw',
      'is_nsfw',
    ];
    if (flagKeys.any((key) => _isAffirmative(json[key]))) return true;

    final ageRating = (json['age_rating'] ?? json['content_rating'] ?? json['maturity_rating'])
        ?.toString()
        .trim();
    return ageRating != null && _adultRating.hasMatch(ageRating);
  }

  /// Returns null unless provider metadata verifies this as a playable short
  /// movie. Unknown numeric provider types and any explicit adult marker are
  /// deliberately rejected.
  static ProviderClip? fromProviderJson(Map<String, dynamic> json) {
    String value(Object? input) => input?.toString().trim() ?? '';

    final providerType = value(json['type'] ?? json['subject_type'] ?? json['subjectType']).toLowerCase();
    // In MovieBox, movies have type 'movie' or numeric subjectType 1 (vs 2 for TV series).
    if ((providerType != 'movie' && providerType != '1') || _isAdultRecord(json)) return null;

    final rawGenre = json['genre'] ?? json['genres'];
    final genres = rawGenre is List
        ? rawGenre.map(value).where((tag) => tag.isNotEmpty).toList()
        : value(rawGenre)
            .split(',')
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty)
            .toList();
    final normalizedGenres = genres.map((tag) => tag.toLowerCase()).toSet();
    if (!normalizedGenres.any(_shortGenreNames.contains)) return null;
    if (normalizedGenres.any(_adultGenres.contains)) return null;

    final title = value(json['base_title'] ?? json['baseTitle'] ?? json['name'] ?? json['title'] ?? json['subject_title'] ?? json['subjectTitle']);
    var subjectId = value(json['subject_id'] ?? json['subjectId'] ?? json['id']);
    var detailPath = value(json['detail_path'] ?? json['detailPath'] ?? json['slug']);
    if (subjectId.isEmpty && detailPath.isNotEmpty) subjectId = detailPath;
    if (detailPath.isEmpty && subjectId.isNotEmpty) detailPath = subjectId;
    final hasResource = json['has_resource'] == true ||
        json['hasResource'] == true ||
        json['has_resource'] == 1 ||
        json['hasResource'] == 1;
    if (title.isEmpty || subjectId.isEmpty || detailPath.isEmpty || !hasResource) {
      return null;
    }
    if (_explicitTitle.hasMatch(title)) return null;

    final rawYear = value(json['year'] ?? json['release_year'] ?? json['releaseYear'] ?? json['release_date']);
    final year = int.tryParse(rawYear.length >= 4 ? rawYear.substring(0, 4) : rawYear) ?? 0;
    final rawRating = value(json['rating'] ?? json['vote_average'] ?? json['score']);
    final rating = double.tryParse(rawRating) ?? 0.0;
    final rawPosterUrl = ProviderPayload.posterUrl(json);
    final posterUrl = rawPosterUrl.startsWith('https://') ? rawPosterUrl : '';

    return ProviderClip(
      subjectId: subjectId,
      detailPath: detailPath,
      title: title,
      posterUrl: posterUrl,
      genre: genres.join(' • '),
      country: value(json['country']),
      description: value(json['description'] ?? json['overview']),
      year: year,
      rating: rating,
    );
  }

  /// Converts only the viewer-facing fields used by the existing player and
  /// local Continue Watching store. Stream resolution uses [subjectId] and
  /// [detailPath] directly, not a TMDB title search.
  MediaItem toMediaItem() {
    final yearDate = year > 0 ? '$year-01-01' : '';
    return MediaItem(
      id: _stableLocalId(subjectId),
      title: title,
      originalTitle: title,
      overview: description,
      posterPath: null,
      backdropPath: null,
      posterUrlOverride: posterUrl.isNotEmpty ? posterUrl : null,
      backdropUrlOverride: posterUrl.isNotEmpty ? posterUrl : null,
      providerSubjectId: subjectId,
      providerDetailPath: detailPath,
      voteAverage: rating,
      releaseDate: yearDate,
      mediaType: 'movie',
      genreIds: const [],
    );
  }

  static int _stableLocalId(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash = ((hash ^ codeUnit) * 0x01000193) & 0x7fffffff;
    }
    // Negative IDs keep provider titles separate from TMDB's positive IDs in
    // the existing local My List and Continue Watching collections.
    return -(hash + 1);
  }
}
