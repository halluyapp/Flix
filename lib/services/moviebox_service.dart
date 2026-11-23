import '../core/constants/api_constants.dart';
import '../core/provider/provider_failures.dart';
import '../models/caption_load.dart';
import '../models/provider_clip.dart';
import '../models/provider_match.dart';
import '../models/stream_source.dart';
import 'caption_adapter.dart';
import 'moviebox_api_client.dart';
import 'provider_matcher.dart';
import 'provider_payload.dart';

/// Cached play metadata for short-lived caption lookups.
class _CachedPlayInfo {
  final Map<String, dynamic> body;
  final DateTime storedAt;

  _CachedPlayInfo(this.body) : storedAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(storedAt) > const Duration(seconds: 45);
}

/// Official MovieBox H5 API provider repository.
///
/// Replaces the legacy Zarhosting provider. The provider is the playback source
/// only: TMDB remains the primary catalogue and metadata source. Every call goes
/// directly from the Flutter app to the MovieBox H5 API.
class MovieBoxService {
  final MovieBoxApiClient _client;
  final Map<String, _CachedPlayInfo> _playCache = {};

  MovieBoxService({MovieBoxApiClient? client})
      : _client = client ?? MovieBoxApiClient();

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

  /// Searches MovieBox catalogue via POST `/subject/search` and matches the
  /// TMDB title to a provider record using [ProviderMatcher].
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
        final decoded = await _client.postJson(
          '/subject/search',
          query: {'host': ApiConstants.movieboxHost},
          body: {
            'keyword': query,
            'page': 1,
            'perPage': 30,
            'subjectType': 0, // 0 searches all subjects (movies + series)
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
      } on ProviderException catch (error) {
        if (error.type == ProviderErrorType.noProviderMatch) continue;
        return ProviderMatchResult.none(failure: error);
      }
    }

    return ProviderMatchResult.none(failure: lastFailure ?? matcherFailure);
  }

  /// Requests movie streams, or TV episode streams via MovieBox's `/subject/play`.
  ///
  /// Extracts MP4 direct streams, HLS manifests, and DASH streams, preserving
  /// any signed cookies and headers needed by the CDN.
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

    final se = match.isSeries ? season : 0;
    final ep = match.isSeries ? episode : 0;
    final cacheKey = '${match.subjectId}_${match.detailPath}_${se}_$ep';

    final query = <String, String>{
      'subjectId': match.subjectId,
      'detailPath': match.detailPath,
      'se': '$se',
      'ep': '$ep',
      'streamSignType': '1',
      'host': ApiConstants.movieboxHost,
      'supportCodecs[hevc]': '1',
      'supportCodecs[h264]': '1',
    };

    final decoded = await _client.getJson(
      '/subject/play',
      query: query,
      kind: ProviderRequestKind.stream,
      timeout: const Duration(seconds: 18),
    );
    final body = ProviderPayload.bodyOf(decoded);
    _playCache[cacheKey] = _CachedPlayInfo(body);

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

    // Direct MP4 streams: MovieBox returns these under `streams` or `sources`.
    for (final raw in ProviderPayload.listOf(
      body['streams'] ?? body['sources'],
    )) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      if (ProviderPayload.optionalBool(
            item,
            const ['vip_locked', 'vipLocked'],
          ) ==
          true) {
        continue;
      }
      try {
        final cookie = ProviderPayload.string(
          item,
          const ['signCookie', 'sign_cookie', 'cookie'],
        );
        final extra = <String, String>{};
        if (cookie.isNotEmpty) extra['Cookie'] = cookie;
        add(StreamSource.fromProviderJson(item, extraHeaders: extra));
      } on FormatException {
        rejected++;
      }
    }

    // Adaptive HLS streams
    for (final raw in ProviderPayload.listOf(body['hls'])) {
      try {
        add(_adaptiveSource(raw, format: 'HLS'));
      } on FormatException {
        rejected++;
      }
    }

    // Adaptive DASH streams
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

  /// Requests the subtitle list for one exact movie or episode via `/subject/caption`.
  ///
  /// MovieBox's caption endpoint requires the stream ID and format resolved from
  /// `/subject/play`. If [streamId] is omitted, it reuses the recently cached play
  /// metadata or calls `/subject/play` to obtain them.
  Future<CaptionLoad> fetchCaptionLoad({
    required ProviderMatch match,
    int season = 0,
    int episode = 0,
    String? streamId,
    String? format,
    Duration timeout = const Duration(seconds: 10),
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

    final se = match.isSeries ? season : 0;
    final ep = match.isSeries ? episode : 0;
    final cacheKey = '${match.subjectId}_${match.detailPath}_${se}_$ep';

    String? effectiveStreamId = streamId;
    String? effectiveFormat = format;

    // Look for stream id and format in the recent play cache if not provided
    if (effectiveStreamId == null || effectiveStreamId.isEmpty) {
      final cachedPlay = _playCache[cacheKey];
      Map<String, dynamic>? playBody;
      if (cachedPlay != null && !cachedPlay.isExpired) {
        playBody = cachedPlay.body;
      } else {
        try {
          final query = <String, String>{
            'subjectId': match.subjectId,
            'detailPath': match.detailPath,
            'se': '$se',
            'ep': '$ep',
            'streamSignType': '1',
            'host': ApiConstants.movieboxHost,
            'supportCodecs[hevc]': '1',
            'supportCodecs[h264]': '1',
          };
          final decoded = await _client.getJson(
            '/subject/play',
            query: query,
            kind: ProviderRequestKind.stream,
            timeout: timeout,
            maxAttempts: 2,
          );
          playBody = ProviderPayload.bodyOf(decoded);
          _playCache[cacheKey] = _CachedPlayInfo(playBody);
        } catch (_) {
          // If play resolution fails, we attempt caption fetch with identifiers alone
        }
      }

      if (playBody != null) {
        final streams = ProviderPayload.listOf(
          playBody['streams'] ?? playBody['sources'],
        );
        final dash = ProviderPayload.listOf(playBody['dash']);
        if (streams.isNotEmpty && streams.first is Map) {
          final first = streams.first as Map;
          effectiveStreamId = first['id']?.toString();
          effectiveFormat = first['format']?.toString() ?? 'MP4';
        } else if (dash.isNotEmpty && dash.first is Map) {
          final first = dash.first as Map;
          effectiveStreamId = first['id']?.toString();
          effectiveFormat = first['format']?.toString() ?? 'DASH';
        }
      }
    }

    final query = <String, String>{
      if (effectiveFormat != null && effectiveFormat.isNotEmpty)
        'format': effectiveFormat,
      if (effectiveStreamId != null && effectiveStreamId.isNotEmpty)
        'id': effectiveStreamId,
      'subjectId': match.subjectId,
      'detailPath': match.detailPath,
      'se': match.isSeries ? '$season' : '0',
      'ep': match.isSeries ? '$episode' : '0',
      'host': ApiConstants.movieboxHost,
    };

    final decoded = await _client.getJson(
      '/subject/caption',
      query: query,
      kind: ProviderRequestKind.captions,
      timeout: timeout,
      maxAttempts: 2,
    );
    return CaptionResponseAdapter.parse(decoded);
  }

  /// Discovery rail for the Clips tab. Uses MovieBox's catalogue search
  /// to filter for verified playable short films.
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
      final decoded = await _client.postJson(
        '/subject/search',
        query: {'host': ApiConstants.movieboxHost},
        body: {
          'keyword': query,
          'page': page,
          'perPage': 30,
          'subjectType': 0,
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
          (root['total_pages'] is num && (root['total_pages'] as num) > page) ||
          (root['pager'] is Map &&
              (root['pager']['totalCount'] is num) &&
              ((root['pager']['totalCount'] as num) > page * 30));
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

  String get baseUrl => _client.baseUrl;
}

class _ProviderSearchPage {
  final List<ProviderClip> items;
  final bool hasMore;

  const _ProviderSearchPage({required this.items, required this.hasMore});

  const _ProviderSearchPage.empty()
      : items = const [],
        hasMore = false;
}

/// Backwards-compatibility alias for ZarhostingService.
typedef ZarhostingService = MovieBoxService;
