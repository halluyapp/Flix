import '../core/constants/api_constants.dart';
import '../core/provider/provider_failures.dart';
import '../models/caption_track.dart';
import '../models/provider_clip.dart';
import '../models/provider_match.dart';
import '../models/stream_source.dart';
import 'provider_matcher.dart';
import 'provider_payload.dart';
import 'zarhosting_api_client.dart';

/// Direct Zarhosting provider repository.
///
/// The provider is the playback source only: TMDB remains the catalogue and
/// metadata source. Every call goes straight from the Flutter app to the
/// provider; nothing is proxied through Supabase.
class ZarhostingService {
  final ZarhostingApiClient _client;

  ZarhostingService({ZarhostingApiClient? client})
      : _client = client ?? ZarhostingApiClient();

  static const List<String> _shortFilmSearches = [
    'animated short film',
    'short animation',
    'animation short',
    'short film',
  ];

  static String normalizeTitle(String raw) => ProviderMatcher.normalize(raw);

  static double calculateSimilarity(String s1, String s2) =>
      ProviderMatcher.similarity(s1, s2);

  static String comparisonTitle(String raw) =>
      ProviderMatcher.comparisonTitle(raw);

  /// Searches the provider and matches the TMDB title to a provider record.
  ///
  /// Provider match metadata is what gets cached by [StreamResolver]; signed
  /// stream URLs never are.
  Future<ProviderMatchResult> findMatch({
    required String title,
    String? originalTitle,
    required int year,
    required bool isSeries,
  }) async {
    final primary = title.trim();
    final alternate = originalTitle?.trim() ?? '';
    final queries = <String>[
      if (primary.isNotEmpty) primary,
      if (alternate.isNotEmpty &&
          ProviderMatcher.normalize(alternate) !=
              ProviderMatcher.normalize(primary))
        alternate,
    ];
    if (queries.isEmpty) {
      return ProviderMatchResult.none(
        failure: const ProviderException(
          ProviderErrorType.noProviderMatch,
          'This title has no name to search the provider with.',
        ),
      );
    }

    ProviderException? lastFailure;
    ProviderException? matcherFailure;
    for (final query in queries) {
      try {
        final decoded = await _client.getJson(
          '/search',
          query: {
            'q': query,
            'page': '1',
            'per_page': '30',
          },
          kind: ProviderRequestKind.search,
          timeout: const Duration(seconds: 12),
        );
        final items = ProviderPayload.itemsOf(decoded);
        if (items.isEmpty) {
          lastFailure = null;
          continue;
        }
        final result = ProviderMatcher.select(
          items: items,
          title: primary.isNotEmpty ? primary : alternate,
          originalTitle: alternate.isEmpty ? null : alternate,
          year: year,
          isSeries: isSeries,
        );
        if (result.isMatched || result.isAmbiguous) return result;
        matcherFailure = result.failure ?? matcherFailure;
        // A genuine no-match may still be worth retrying with the original
        // title, so keep looking before giving up.
      } on ProviderException catch (error) {
        if (error.type == ProviderErrorType.noProviderMatch) continue;
        // Transport and provider failures are terminal for this attempt: a
        // second query would just repeat the same outage.
        return ProviderMatchResult.none(failure: error);
      }
    }

    return ProviderMatchResult.none(failure: lastFailure ?? matcherFailure);
  }

  /// Requests movie streams, or TV episode streams using the provider's exact
  /// `se`/`ep` contract. Movies never send episode parameters.
  Future<List<StreamSource>> resolveStreams({
    required ProviderMatch match,
    int season = 0,
    int episode = 0,
  }) async {
    if (!match.hasDistinctIdentifiers) {
      throw const ProviderException(
        ProviderErrorType.missingProviderIdentifier,
        'The provider match is missing its subject ID or detail path.',
      );
    }
    if (match.isSeries && (season < 1 || episode < 1)) {
      throw const ProviderException(
        ProviderErrorType.missingProviderIdentifier,
        'A TV episode needs both a season and an episode number.',
      );
    }

    final query = <String, String>{'detail_path': match.detailPath};
    if (match.isSeries) {
      query['se'] = '$season';
      query['ep'] = '$episode';
    }

    final decoded = await _client.getJson(
      '/stream/${Uri.encodeComponent(match.subjectId)}',
      query: query,
      kind: ProviderRequestKind.stream,
      timeout: const Duration(seconds: 18),
    );
    final body = ProviderPayload.bodyOf(decoded);

    final bodyError = ProviderPayload.string(body, const ['error']);
    if (bodyError.isNotEmpty) {
      throw ProviderException(
        bodyError == 'upstream_error'
            ? ProviderErrorType.providerUnavailable
            : ProviderErrorType.invalidProviderResponse,
        'The provider could not return a stream for this title.',
        diagnostic: bodyError,
      );
    }
    if (ProviderPayload.optionalBool(
          body,
          const ['has_resource', 'hasResource'],
        ) ==
        false) {
      throw const ProviderException(
        ProviderErrorType.noPlayableSources,
        'The provider has no playable resource for this title.',
      );
    }

    final sources = <StreamSource>[];
    final seenUrls = <String>{};
    var previewOnly = false;
    var rejected = 0;

    void add(StreamSource source) {
      if (source.isPreview) {
        previewOnly = true;
        return;
      }
      if (!source.isPlayableFormat) {
        rejected++;
        return;
      }
      if (seenUrls.add(source.url)) sources.add(source);
    }

    for (final raw in ProviderPayload.listOf(
      body['sources'] ?? body['streams'],
    )) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      if (ProviderPayload.optionalBool(
            item,
            const ['vip_locked', 'vipLocked'],
          ) ==
          true) {
        // The CDN rejects VIP-locked entries at playback time.
        continue;
      }
      try {
        add(StreamSource.fromProviderJson(item));
      } on FormatException {
        rejected++;
      }
    }

    for (final raw in ProviderPayload.listOf(body['hls'])) {
      try {
        add(_adaptiveSource(raw, format: 'HLS'));
      } on FormatException {
        rejected++;
      }
    }

    for (final raw in ProviderPayload.listOf(body['dash'])) {
      try {
        add(_adaptiveSource(raw, format: 'DASH'));
      } on FormatException {
        rejected++;
      }
    }

    if (sources.isEmpty) {
      throw ProviderException(
        ProviderErrorType.noPlayableSources,
        previewOnly
            ? 'Only a trailer or preview is available for this title.'
            : rejected > 0
                ? 'The provider returned sources in an unsupported format.'
                : 'The provider returned no playable source for this title.',
        diagnostic: 'sources=0 previews=$previewOnly rejected=$rejected',
      );
    }

    sources.sort(_compareSources);
    return sources;
  }

  StreamSource _adaptiveSource(dynamic raw, {required String format}) {
    final url = raw is Map
        ? (raw['url'] ?? raw['stream_url'] ?? raw['file'] ?? '').toString()
        : raw?.toString() ?? '';
    final map = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{'url': url};

    final headers = <String, String>{};
    final cookie = ProviderPayload.string(
      map,
      const ['signCookie', 'sign_cookie', 'cookie'],
    );
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;

    final resolved = StreamSource.fromProviderJson(
      {
        ...map,
        'url': url,
        'format': format,
      },
      extraHeaders: headers,
    );
    return resolved;
  }

  static int _compareSources(StreamSource a, StreamSource b) {
    // Direct MP4 files first: they play and download most reliably.
    final formatOrder = a.isMp4 ? 0 : (a.isHls ? 1 : 2);
    final otherFormatOrder = b.isMp4 ? 0 : (b.isHls ? 1 : 2);
    if (formatOrder != otherFormatOrder) {
      return formatOrder.compareTo(otherFormatOrder);
    }
    final qualityOrder = b.qualityValue.compareTo(a.qualityValue);
    if (qualityOrder != 0) return qualityOrder;
    return a.format.compareTo(b.format);
  }

  /// Caption discovery is best-effort: a caption failure must never stop
  /// video playback. Returns an empty list when the provider has none.
  Future<List<CaptionTrack>> fetchCaptions({
    required ProviderMatch match,
    int season = 0,
    int episode = 0,
  }) async {
    if (!match.hasDistinctIdentifiers) return const [];
    if (match.isSeries && (season < 1 || episode < 1)) return const [];

    final query = <String, String>{'detail_path': match.detailPath};
    if (match.isSeries) {
      query['se'] = '$season';
      query['ep'] = '$episode';
    } else {
      query['se'] = '0';
      query['ep'] = '0';
    }

    try {
      final decoded = await _client.getJson(
        '/stream/${Uri.encodeComponent(match.subjectId)}/captions',
        query: query,
        kind: ProviderRequestKind.captions,
        timeout: const Duration(seconds: 12),
      );
      final body = ProviderPayload.bodyOf(decoded);
      final tracks = <CaptionTrack>[];
      final seenLanguages = <String>{};
      for (final raw in ProviderPayload.listOf(
        body['captions'] ?? body['subtitles'],
      )) {
        if (raw is! Map) continue;
        final track = CaptionTrack.fromJson(Map<String, dynamic>.from(raw));
        if (!track.isSecure) continue;
        if (!seenLanguages.add(track.language)) continue;
        tracks.add(track);
      }
      return tracks;
    } on ProviderException catch (error) {
      if (error.type == ProviderErrorType.networkUnavailable) rethrow;
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// Discovery rail for the Clips tab. Only provider records that explicitly
  /// declare the Short genre, a movie type and an available resource qualify.
  Future<List<ProviderClip>> searchShortFilms() async {
    final firstPages = await Future.wait(
      _shortFilmSearches.map((query) => _searchCatalog(query, page: 1)),
    );
    final discovered = <String, ProviderClip>{};

    void addPage(_ProviderSearchPage page) {
      for (final clip in page.items) {
        final key = '${normalizeTitle(clip.title)}_${clip.year}';
        final existing = discovered[key];
        if (existing == null || clip.rating > existing.rating) {
          discovered[key] = clip;
        }
      }
    }

    for (final page in firstPages) {
      addPage(page);
    }

    if (discovered.length < 18) {
      final nextPages = <Future<_ProviderSearchPage>>[];
      for (var index = 0;
          index < firstPages.length && nextPages.length < 4;
          index++) {
        if (firstPages[index].hasMore) {
          nextPages.add(_searchCatalog(_shortFilmSearches[index], page: 2));
        }
      }
      for (final page in await Future.wait(nextPages)) {
        addPage(page);
      }
    }

    final clips = discovered.values.toList()
      ..sort((a, b) {
        final ratingOrder = b.rating.compareTo(a.rating);
        if (ratingOrder != 0) return ratingOrder;
        final yearOrder = b.year.compareTo(a.year);
        return yearOrder != 0 ? yearOrder : a.title.compareTo(b.title);
      });
    return clips.take(48).toList();
  }

  Future<_ProviderSearchPage> _searchCatalog(
    String query, {
    required int page,
  }) async {
    try {
      final decoded = await _client.getJson(
        '/search',
        query: {
          'q': query,
          'page': '$page',
          'per_page': '30',
        },
        kind: ProviderRequestKind.search,
        timeout: const Duration(seconds: 14),
      );
      final items = ProviderPayload.itemsOf(decoded)
          .whereType<Map>()
          .map((raw) =>
              ProviderClip.fromProviderJson(Map<String, dynamic>.from(raw)))
          .whereType<ProviderClip>()
          .toList();
      final root = ProviderPayload.bodyOf(decoded);
      final hasMore = root['has_more'] == true ||
          root['hasMore'] == true ||
          (root['total_pages'] is num && (root['total_pages'] as num) > page);
      return _ProviderSearchPage(items: items, hasMore: hasMore);
    } catch (_) {
      return const _ProviderSearchPage.empty();
    }
  }

  /// Convenience used by the Clips player, which already has exact provider
  /// identifiers rather than a TMDB title.
  Future<ProviderMatch> requireMatch({
    required String title,
    required int year,
    required bool isSeries,
  }) async {
    final result = await findMatch(
      title: title,
      year: year,
      isSeries: isSeries,
    );
    if (!result.isMatched) {
      throw result.asFailure ??
          const ProviderException(
            ProviderErrorType.noProviderMatch,
            'This title is not available on the provider.',
          );
    }
    return result.match!;
  }

  String get baseUrl => ApiConstants.zarhostingBaseUrl;
}

class _ProviderSearchPage {
  final List<ProviderClip> items;
  final bool hasMore;

  const _ProviderSearchPage({required this.items, required this.hasMore});

  const _ProviderSearchPage.empty()
      : items = const [],
        hasMore = false;
}
