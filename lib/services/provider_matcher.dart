import '../core/provider/provider_failures.dart';
import '../models/provider_match.dart';
import 'provider_payload.dart';

/// Deterministic TMDB-to-provider matching.
///
/// Title normalization alone is never enough: media type, release year and the
/// provider's own base title all contribute, and a low-confidence result is
/// never silently played.
class ProviderMatcher {
  const ProviderMatcher._();

  /// Minimum confidence before Flix will auto-play a provider result.
  static const double matchThreshold = 0.74;

  /// Two credible results inside this window are treated as ambiguous.
  static const double ambiguityWindow = 0.05;

  /// Below this title similarity a candidate is not credible at all.
  static const double _titleFloor = 0.6;

  static const Map<String, String> _diacritics = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
    'ç': 'c', 'ć': 'c', 'č': 'c',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ę': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ñ': 'n', 'ń': 'n',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
    'š': 's', 'ś': 's',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
    'ý': 'y', 'ÿ': 'y', 'ž': 'z', 'ź': 'z', 'ż': 'z',
    'œ': 'oe', 'æ': 'ae', 'ß': 'ss',
    'ł': 'l',
  };

  /// Lowercase, diacritic-free, punctuation-free, single-spaced title.
  static String normalize(String raw) {
    var value = raw.toLowerCase().trim();
    for (final entry in _diacritics.entries) {
      value = value.replaceAll(entry.key, entry.value);
    }
    return value
        .replaceAll('&', ' and ')
        .replaceAll(RegExp(r"['`\u2018\u2019\u201c\u201d]"), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Normalization used only for comparison: provider titles often carry a
  /// language badge, a season suffix or a quality tag that TMDB does not.
  static String comparisonTitle(String raw) {
    var value = raw;
    value = value.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    value = value.replaceAll(RegExp(r'\((?:[^)]*)\)'), ' ');
    value = value.replaceAll(
      RegExp(r'\b(?:s\d{1,2}(?:e\d{1,3})?|season\s?\d{1,2}|episode\s?\d{1,3})\b',
          caseSensitive: false),
      ' ',
    );
    value = value.replaceAll(
      RegExp(r'\b(?:1080p|720p|480p|360p|2160p|4k|uhd|hd|sd|web[- ]?dl|webrip|bluray|brrip|hdcam|cam|hevc|h264|x264|x265)\b',
          caseSensitive: false),
      ' ',
    );
    value = value.replaceAll(
      RegExp(r'\b(?:dubbed|dub|subbed|sub|full movie|official)\b',
          caseSensitive: false),
      ' ',
    );
    return normalize(value);
  }

  /// Token-based similarity in the range 0..1.
  ///
  /// Exact normalized matches score 1.0, whole-word containment scores 0.9 and
  /// otherwise the Dice coefficient over meaningful words is used.
  static double similarity(String a, String b) {
    final left = normalize(a);
    final right = normalize(b);
    if (left.isEmpty || right.isEmpty) return 0;
    if (left == right) return 1;
    if (_containsWords(left, right) || _containsWords(right, left)) return 0.9;

    final leftWords = left.split(' ').where((w) => w.length > 1).toSet();
    final rightWords = right.split(' ').where((w) => w.length > 1).toSet();
    if (leftWords.isEmpty || rightWords.isEmpty) return 0;
    final intersection = leftWords.intersection(rightWords).length;
    return (2 * intersection) / (leftWords.length + rightWords.length);
  }

  static bool _containsWords(String haystack, String needle) {
    if (needle.isEmpty) return false;
    return RegExp('(^| )${RegExp.escape(needle)}( |\$)').hasMatch(haystack);
  }

  static bool isSeriesItem(Map<String, dynamic> item) {
    final type = ProviderPayload.string(
      item,
      const ['type', 'subject_type', 'subjectType'],
    ).toLowerCase();
    if (type == 'tv' || type == 'series' || type == 'show' || type == '2') {
      return true;
    }
    if (type == 'movie' || type == 'film' || type == '1') return false;
    final seasons = item['seasons'];
    return seasons is List && seasons.isNotEmpty;
  }

  static bool _isDub(Map<String, dynamic> item) {
    final explicit = ProviderPayload.optionalBool(item, const ['dub', 'is_dub']);
    if (explicit != null) return explicit;
    final audio = ProviderPayload.string(
      item,
      const ['audio', 'language', 'badge'],
    ).toLowerCase();
    if (audio.isEmpty) return false;
    return !audio.contains('original');
  }

  /// Scores provider records and returns a safe match, an ambiguity selection
  /// or a no-match result.
  static ProviderMatchResult select({
    required List<dynamic> items,
    required String title,
    String? originalTitle,
    required int year,
    required bool isSeries,
  }) {
    final bestByIdentity = <String, _ScoredCandidate>{};
    var missingIdentifier = 0;
    var typeMismatch = 0;

    for (final raw in items) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);

      final subjectId = ProviderPayload.string(
        item,
        const ['subject_id', 'subjectId', 'id'],
      );
      final detailPath = ProviderPayload.string(
        item,
        const ['detail_path', 'detailPath', 'slug'],
      );
      if (subjectId.isEmpty ||
          detailPath.isEmpty ||
          subjectId == detailPath) {
        missingIdentifier++;
        continue;
      }
      if (ProviderPayload.optionalBool(
            item,
            const ['has_resource', 'hasResource'],
          ) ==
          false) {
        continue;
      }
      if (isSeriesItem(item) != isSeries) {
        typeMismatch++;
        continue;
      }

      final providerTitle = ProviderPayload.string(
        item,
        const ['name', 'title', 'subject_title', 'subjectTitle'],
      );
      final providerBaseTitle = ProviderPayload.string(
        item,
        const ['base_title', 'baseTitle'],
      );
      final titleScore = _titleScore(
        title: title,
        originalTitle: originalTitle,
        providerTitle: providerTitle,
        providerBaseTitle: providerBaseTitle,
      );
      if (titleScore < _titleFloor) continue;

      final providerYear = ProviderPayload.year(item);
      final yearScore = _yearScore(
        requestedYear: year,
        providerYear: providerYear,
        isSeries: isSeries,
      );

      var confidence = (titleScore * 0.62) + (yearScore * 0.28) + 0.10;
      final dub = _isDub(item);
      if (dub) {
        confidence -= 0.02;
      } else {
        confidence += 0.01;
      }
      confidence = confidence.clamp(0.0, 1.0).toDouble();

      final poster = ProviderPayload.string(
        item,
        const ['poster_url', 'posterUrl'],
      );
      final audioLanguage = ProviderPayload.string(
        item,
        const ['audio', 'language', 'badge'],
      );
      final candidate = ProviderMatch(
        subjectId: subjectId,
        detailPath: detailPath,
        title: providerTitle.isNotEmpty ? providerTitle : providerBaseTitle,
        baseTitle: providerBaseTitle,
        year: providerYear,
        isSeries: isSeries,
        confidence: confidence,
        audioLanguage: audioLanguage.isEmpty ? null : audioLanguage,
        isDub: dub,
        posterUrl: poster.startsWith('https://') ? poster : null,
        subtitleLanguages: ProviderPayload.stringList(
          item,
          const ['subtitles'],
        ),
      );

      final existing = bestByIdentity[subjectId];
      if (existing == null || candidate.confidence > existing.match.confidence) {
        bestByIdentity[subjectId] = _ScoredCandidate(match: candidate);
      }
    }

    final scored = bestByIdentity.values.toList()
      ..sort((a, b) {
        final byConfidence = b.match.confidence.compareTo(a.match.confidence);
        if (byConfidence != 0) return byConfidence;
        return a.match.title.compareTo(b.match.title);
      });

    if (scored.isEmpty) {
      if (missingIdentifier > 0 && typeMismatch == 0) {
        return ProviderMatchResult.none(
          failure: const ProviderException(
            ProviderErrorType.missingProviderIdentifier,
            'Provider results were missing a playable subject ID or detail path.',
          ),
        );
      }
      return ProviderMatchResult.none();
    }

    final top = scored.first;
    if (top.match.confidence < matchThreshold) {
      return ProviderMatchResult.none();
    }

    final runnerUp = scored.skip(1).firstWhere(
          (candidate) =>
              candidate.match.subjectId != top.match.subjectId &&
              candidate.match.confidence >= matchThreshold,
          orElse: () => top,
        );
    if (runnerUp.match.subjectId != top.match.subjectId &&
        (top.match.confidence - runnerUp.match.confidence) < ambiguityWindow) {
      // Dubbed/original variants of the same title and year are one work, not
      // two credible matches: prefer the higher-confidence version instead of
      // asking the viewer to choose between audio dubs.
      final identicalWork = _sameWork(top.match, runnerUp.match);
      if (!identicalWork) {
        final candidates = scored
            .where((candidate) => candidate.match.confidence >= matchThreshold)
            .map((candidate) => candidate.match)
            .toList(growable: false);
        return ProviderMatchResult.ambiguous(candidates);
      }
    }

    return ProviderMatchResult.matched(top.match);
  }

  static double _titleScore({
    required String title,
    String? originalTitle,
    required String providerTitle,
    required String providerBaseTitle,
  }) {
    final queries = <String>[
      title,
      if (originalTitle != null && originalTitle.trim().isNotEmpty)
        originalTitle,
    ];
    final providerTitles = <String>[
      providerTitle,
      if (providerBaseTitle.isNotEmpty) providerBaseTitle,
    ];
    var best = 0.0;
    for (final query in queries) {
      final normalizedQuery = comparisonTitle(query);
      if (normalizedQuery.isEmpty) continue;
      for (final provider in providerTitles) {
        final normalizedProvider = comparisonTitle(provider);
        if (normalizedProvider.isEmpty) continue;
        final score = _similarityNormalized(
          normalizedQuery,
          normalizedProvider,
        );
        if (score > best) best = score;
      }
    }
    return best;
  }

  static double _similarityNormalized(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (_containsWords(a, b) || _containsWords(b, a)) return 0.9;
    final leftWords = a.split(' ').where((w) => w.length > 1).toSet();
    final rightWords = b.split(' ').where((w) => w.length > 1).toSet();
    if (leftWords.isEmpty || rightWords.isEmpty) return 0;
    final intersection = leftWords.intersection(rightWords).length;
    return (2 * intersection) / (leftWords.length + rightWords.length);
  }

  static bool _sameWork(ProviderMatch a, ProviderMatch b) {
    final titleA = comparisonTitle(a.baseTitle.isNotEmpty ? a.baseTitle : a.title);
    final titleB = comparisonTitle(b.baseTitle.isNotEmpty ? b.baseTitle : b.title);
    if (titleA != titleB) return false;
    if (a.year <= 0 || b.year <= 0) return true;
    return (a.year - b.year).abs() <= 1;
  }

  static double _yearScore({
    required int requestedYear,
    required int providerYear,
    required bool isSeries,
  }) {
    // Missing year on either side is neutral rather than a rejection: many
    // provider records omit a usable year.
    if (requestedYear <= 0 || providerYear <= 0) return 0.5;
    final difference = (requestedYear - providerYear).abs();
    if (difference == 0) return 1;
    if (difference == 1) return 0.8;
    if (difference == 2) return 0.45;
    if (isSeries) {
      // Season records are dated by season release year, not by the show's
      // first air year, so a wider tolerance is legitimate here.
      return difference <= 10 ? 0.25 : 0.05;
    }
    return 0;
  }
}

class _ScoredCandidate {
  final ProviderMatch match;

  const _ScoredCandidate({
    required this.match,
  });
}

