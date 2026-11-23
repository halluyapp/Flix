import 'dart:convert';

import '../core/constants/api_constants.dart';
import '../core/provider/provider_failures.dart';
import '../models/caption_load.dart';
import '../models/caption_track.dart';
import '../models/provider_clip.dart';
import '../models/provider_match.dart';
import '../models/stream_source.dart';
import 'caption_adapter.dart';
import 'provider_matcher.dart';
import 'provider_payload.dart';
import 'zarhosting_api_client.dart';

class ZarhostingService {
  final ZarhostingApiClient _client;

  // Cache stream IDs for quick caption correlation in MovieBox H5 API
  final Map<String, String> _streamIdCache = {};

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


  bool get _isMovieBoxApi =>
      !_client.baseUrl.contains('example.com') &&
      !_client.baseUrl.contains('movieapi.zarhosting');

  /// Locates the best-matching provider title. Searches the primary title
  /// first and falls back to originalTitle when the original title is
  /// distinctly different.
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
        final Map<String, dynamic> decoded;
        if (_isMovieBoxApi) {
          decoded = await _client.postJson(
            '/subject/search',
            body: {
              'keyword': query,
              'page': 1,
              'perPage': 30,
              'subjectType': 0,
            },
            kind: ProviderRequestKind.search,
            timeout: const Duration(seconds: 14),
          );
        } else {
          decoded = await _client.getJson(
            '/search',
            query: {'q': query, 'page': '1', 'per_page': '30'},
            kind: ProviderRequestKind.search,
            timeout: const Duration(seconds: 14),
          );
        }

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

  /// Resolves the playable and downloadable stream sources for a matched
  /// movie or exact TV episode.
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
    final detailPath = match.detailPath;
    final subjectId = match.subjectId;

    final Map<String, dynamic> decoded;
    if (_isMovieBoxApi) {
      final query = <String, String>{
        'subjectId': subjectId,
        'se': '$se',
        'ep': '$ep',
        'detailPath': detailPath,
        'streamSignType': '1',
        'supportCodecs[h264]': '1',
        'supportCodecs[hevc]': '1',
      };
      final playReferer =
          '${ApiConstants.movieboxRefererBase}$detailPath?id=$subjectId&detailSe=$se&detailEp=$ep&lang=en';

      decoded = await _client.getJson(
        '/subject/play',
        query: query,
        extraHeaders: {
          'Referer': playReferer,
          'Origin': ApiConstants.movieboxOrigin,
          'X-Vip-Restrict': '0',
        },
        kind: ProviderRequestKind.stream,
        timeout: const Duration(seconds: 18),
      );
    } else {
      final query = <String, String>{
        'detail_path': detailPath,
        if (match.isSeries) 'se': '$se',
        if (match.isSeries) 'ep': '$ep',
      };
      decoded = await _client.getJson(
        '/stream/${Uri.encodeComponent(subjectId)}',
        query: query,
        kind: ProviderRequestKind.stream,
        timeout: const Duration(seconds: 18),
      );
    }

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

    // Direct MP4 streams
    final rawStreams = ProviderPayload.listOf(
      body['streams'] ?? body['sources'],
    );
    for (final raw in rawStreams) {
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
        final src = StreamSource.fromProviderJson(
          item,
          extraHeaders: ApiConstants.movieboxMediaHeaders,
        );
        add(src);
        final streamId =
            ProviderPayload.string(item, const ['id', 'stream_id']);
        if (streamId.isNotEmpty) {
          _streamIdCache['$subjectId|$se|$ep'] = streamId;
        }
      } on FormatException {
        rejected++;
      }
    }

    // HLS adaptive streams
    for (final raw in ProviderPayload.listOf(body['hls'])) {
      try {
        add(_adaptiveSource(raw, format: 'HLS'));
      } on FormatException {
        rejected++;
      }
    }

    // DASH adaptive streams
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

  /// Fetches available subtitle tracks for a matched movie or episode.
  /// Never throws: errors are returned cleanly inside the [CaptionLoad].
  Future<CaptionLoad> fetchCaptionLoad({
    required ProviderMatch match,
    int season = 0,
    int episode = 0,
    String? streamId,
    Duration? timeout,
  }) async {
    final se = match.isSeries ? season : 0;
    final ep = match.isSeries ? episode : 0;
    final cacheKey = '${match.subjectId}|$se|$ep';

    try {
      final Map<String, dynamic> decoded;
      if (_isMovieBoxApi) {
        var resolvedId = streamId ?? _streamIdCache[cacheKey];
        if (resolvedId == null || resolvedId.isEmpty) {
          try {
            final playQuery = <String, String>{
              'subjectId': match.subjectId,
              'se': '$se',
              'ep': '$ep',
              'detailPath': match.detailPath,
              'streamSignType': '1',
            };
            final playDecoded = await _client.getJson(
              '/subject/play',
              query: playQuery,
              extraHeaders: {
                'Referer':
                    '${ApiConstants.movieboxRefererBase}${match.detailPath}?id=${match.subjectId}&detailSe=$se&detailEp=$ep&lang=en',
                'Origin': ApiConstants.movieboxOrigin,
                'X-Vip-Restrict': '0',
              },
              kind: ProviderRequestKind.stream,
              timeout: timeout ?? const Duration(seconds: 8),
            );
            final body = ProviderPayload.bodyOf(playDecoded);
            final streams =
                ProviderPayload.listOf(body['streams'] ?? body['sources']);
            for (final raw in streams) {
              if (raw is Map) {
                final id = ProviderPayload.string(
                    Map<String, dynamic>.from(raw), const ['id', 'stream_id']);
                if (id.isNotEmpty) {
                  resolvedId = id;
                  _streamIdCache[cacheKey] = id;
                  break;
                }
              }
            }
          } catch (_) {}
        }

        final query = <String, String>{
          'format': 'MP4',
          if (resolvedId != null && resolvedId.isNotEmpty) 'id': resolvedId,
          'subjectId': match.subjectId,
          'detailPath': match.detailPath,
        };

        decoded = await _client.getJson(
          '/subject/caption',
          query: query,
          extraHeaders: {
            'Referer': '${ApiConstants.movieboxRefererBase}${match.detailPath}',
            'Origin': ApiConstants.movieboxOrigin,
          },
          kind: ProviderRequestKind.captions,
          timeout: timeout ?? const Duration(seconds: 10),
        );
      } else {
        final query = <String, String>{
          'detail_path': match.detailPath,
          if (match.isSeries) 'se': '$se',
          if (match.isSeries) 'ep': '$ep',
        };
        decoded = await _client.getJson(
          '/stream/${Uri.encodeComponent(match.subjectId)}/captions',
          query: query,
          kind: ProviderRequestKind.captions,
          timeout: timeout ?? const Duration(seconds: 10),
        );
      }

      final tracks = CaptionResponseAdapter.parse(decoded);
      return CaptionLoad.loaded(tracks);
    } on ProviderException catch (error) {
      if (error.statusCode == 404 ||
          error.type == ProviderErrorType.noProviderMatch) {
        return CaptionLoad.empty();
      }
      return CaptionLoad.failed(error);
    } catch (error) {
      return CaptionLoad.failed(
        ProviderException(
          ProviderErrorType.unknown,
          'Could not load subtitles.',
          diagnostic: error.runtimeType.toString(),
        ),
      );
    }
  }

  /// Discovery endpoint for the short films feed.
  Future<List<ProviderClip>> searchShortFilms({
    int page = 1,
    int perPage = 20,
    String? query,
  }) async {
    final keyword = (query == null || query.trim().isEmpty)
        ? 'short animation'
        : query.trim();

    final Map<String, dynamic> decoded;
    if (_isMovieBoxApi) {
      decoded = await _client.postJson(
        '/subject/search',
        body: {
          'keyword': keyword,
          'page': page,
          'perPage': perPage,
          'subjectType': 0,
        },
        kind: ProviderRequestKind.search,
        timeout: const Duration(seconds: 14),
      );
    } else {
      decoded = await _client.getJson(
        '/search',
        query: {
          'q': keyword,
          'page': '$page',
          'per_page': '$perPage',
        },
        kind: ProviderRequestKind.search,
        timeout: const Duration(seconds: 14),
      );
    }

    final items = ProviderPayload.itemsOf(decoded);
    final clips = <ProviderClip>[];

    for (final item in items) {
      try {
        final clip = ProviderClip.fromProviderJson(item);
        if (clip != null && !clip.isPornographic) {
          clips.add(clip);
        }
      } catch (_) {}
    }
    return clips;
  }

  StreamSource _adaptiveSource(dynamic raw, {required String format}) {
    if (raw is! Map) {
      throw const FormatException('adaptive source is not a JSON object');
    }
    final item = Map<String, dynamic>.from(raw);
    final url = ProviderPayload.string(item, const ['url', 'play_url']);
    if (url.isEmpty) {
      throw const FormatException('adaptive source has no url');
    }

    final headers = <String, String>{
      ...ApiConstants.movieboxMediaHeaders,
    };

    final cookie =
        ProviderPayload.string(item, const ['signCookie', 'sign_cookie']);
    if (cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }

    final signHeaderKey = ProviderPayload.string(
        item, const ['signHeaderKey', 'sign_header_key']);
    final signHeaderValue = ProviderPayload.string(
        item, const ['signHeaderValue', 'sign_header_value', 'signCookie']);
    if (signHeaderKey.isNotEmpty && signHeaderValue.isNotEmpty) {
      headers[signHeaderKey] = signHeaderValue;
    }

    return StreamSource(
      url: url,
      format: format,
      resolution: ProviderPayload.string(item, const ['resolution'])
          .replaceAll(RegExp(r'[^0-9]'), ''),
      sizeBytes: ProviderPayload.optionalInt(item, const ['size', 'size_bytes']),
      durationSeconds: ProviderPayload.optionalInt(
          item, const ['duration', 'duration_seconds']),
      codec: ProviderPayload.string(item, const ['codec', 'codecName']),
      extraHeaders: headers,
      vipLocked: ProviderPayload.optionalBool(
            item,
            const ['vip_locked', 'vipLocked'],
          ) ??
          false,
    );
  }

  int _compareSources(StreamSource a, StreamSource b) {
    if (a.isDownloadable && !b.isDownloadable) return -1;
    if (!a.isDownloadable && b.isDownloadable) return 1;
    return b.qualityValue.compareTo(a.qualityValue);
  }

  void close() => _client.close();
}

typedef MovieboxService = ZarhostingService;
