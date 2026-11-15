import 'media_item.dart';
import '../core/provider/provider_failures.dart';

/// A provider title that Flix is confident enough to play.
///
/// TMDB IDs, provider subject IDs and provider detail paths are three distinct
/// values. This model never derives one from another.
class ProviderMatch {
  final String subjectId;

  /// The provider's exact `detail_path` (its slug). The stream endpoint fails
  /// with an upstream error when a subject id is sent here instead.
  final String detailPath;
  final String title;
  final String baseTitle;
  final int year;
  final bool isSeries;
  final double confidence;
  final String? audioLanguage;
  final bool isDub;
  final String? posterUrl;
  final List<String> subtitleLanguages;

  const ProviderMatch({
    required this.subjectId,
    required this.detailPath,
    required this.title,
    this.baseTitle = '',
    required this.year,
    required this.isSeries,
    required this.confidence,
    this.audioLanguage,
    this.isDub = false,
    this.posterUrl,
    this.subtitleLanguages = const [],
  });

  /// Builds an explicit match from a provider-backed catalogue item (used by
  /// the Clips feed). Returns null when either identifier is missing or when
  /// the identifiers are the same value, which the provider rejects.
  static ProviderMatch? fromMediaItem(MediaItem item) {
    final subjectId = item.providerSubjectId?.trim() ?? '';
    final detailPath = item.providerDetailPath?.trim() ?? '';
    if (subjectId.isEmpty || detailPath.isEmpty || detailPath == subjectId) {
      return null;
    }
    return ProviderMatch(
      subjectId: subjectId,
      detailPath: detailPath,
      title: item.title,
      baseTitle: item.originalTitle ?? item.title,
      year: item.releaseYear,
      isSeries: item.mediaType == 'tv',
      confidence: 1,
    );
  }

  bool get hasDistinctIdentifiers =>
      subjectId.trim().isNotEmpty &&
      detailPath.trim().isNotEmpty &&
      subjectId.trim() != detailPath.trim();

  String get displayLabel {
    final yearLabel = year > 0 ? ' ($year)' : '';
    final audio = (audioLanguage == null || audioLanguage!.isEmpty)
        ? ''
        : ' · $audioLanguage';
    return '$title$yearLabel$audio';
  }
}

/// Outcome of a provider search + matching pass.
class ProviderMatchResult {
  /// Populated only when Flix is confident enough to play without asking.
  final ProviderMatch? match;

  /// Credible alternatives, used to let the viewer choose safely.
  final List<ProviderMatch> candidates;

  /// Set when the search itself failed (timeout, rate limit, malformed data).
  /// A genuine "nothing matched" result has no failure.
  final ProviderException? failure;

  const ProviderMatchResult({
    this.match,
    this.candidates = const [],
    this.failure,
  });

  factory ProviderMatchResult.matched(ProviderMatch match) =>
      ProviderMatchResult(match: match, candidates: [match]);

  factory ProviderMatchResult.ambiguous(List<ProviderMatch> candidates) =>
      ProviderMatchResult(candidates: List.unmodifiable(candidates));

  factory ProviderMatchResult.none({ProviderException? failure}) =>
      ProviderMatchResult(failure: failure);

  bool get isMatched => match != null;
  bool get isAmbiguous => match == null && candidates.isNotEmpty;
  bool get hasFailure => failure != null;

  ProviderException? get asFailure {
    if (failure != null) return failure;
    if (isAmbiguous) {
      return const ProviderException(
        ProviderErrorType.ambiguousProviderMatch,
        'Several provider titles match this one.',
      );
    }
    return const ProviderException(
      ProviderErrorType.noProviderMatch,
      'This title is not available on the streaming provider.',
    );
  }
}
