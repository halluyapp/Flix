import '../core/constants/api_constants.dart';
import '../core/provider/provider_failures.dart';
import '../models/caption_load.dart';
import '../models/caption_track.dart';
import '../models/media_item.dart';
import '../models/provider_match.dart';
import '../models/stream_source.dart';
import 'diagnostics_service.dart';
import 'zarhosting_service.dart';

/// A successfully resolved playback session.
class ResolvedMediaStream {
  final List<StreamSource> sources;

  /// Subtitle discovery outcome for this exact episode. Playback never waits
  /// for it beyond [StreamResolver.captionBudget].
  final CaptionLoad captionLoad;
  final ProviderMatch match;
  final Map<String, String> mediaHeaders;
  final DateTime resolvedAt;
  final DateTime? expiresAt;

  ResolvedMediaStream({
    required this.sources,
    List<CaptionTrack> captions = const [],
    CaptionLoad? captionLoad,
    required this.match,
    required this.mediaHeaders,
    DateTime? resolvedAt,
    this.expiresAt,
  })  : captionLoad = captionLoad ?? CaptionLoad.ofTracks(captions),
        resolvedAt = resolvedAt ?? DateTime.now();

  List<CaptionTrack> get captions => captionLoad.tracks;

  String get providerTitle => match.title;

  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// Full-length sources the player may use, best first.
  List<StreamSource> get selectableSources => sources
      .where((source) => !source.isPreview && source.isPlayableFormat)
      .toList(growable: false);

  StreamSource? get bestSource =>
      selectableSources.isNotEmpty ? selectableSources.first : null;

  List<StreamSource> get downloadSources => selectableSources
      .where((source) => source.isDownloadable)
      .toList(growable: false);

  /// Sources that can stream but cannot be saved as one offline file.
  List<StreamSource> get streamingOnlySources => selectableSources
      .where((source) => source.isDownloadable == false)
      .toList(growable: false);
}

/// Progress stages so the player can show a different visual for provider
/// matching, stream resolution and player initialisation.
enum ResolutionStage { matchingProvider, resolvingStream }

/// Typed outcome of a TMDB-to-provider playback resolution.
class PlaybackResolution {
  final ResolvedMediaStream? stream;
  final ProviderException? failure;
  final List<ProviderMatch> candidates;

  const PlaybackResolution._({
    this.stream,
    this.failure,
    this.candidates = const [],
  });

  factory PlaybackResolution.success(ResolvedMediaStream stream) =>
      PlaybackResolution._(stream: stream);

  factory PlaybackResolution.failure(
    ProviderException failure, {
    List<ProviderMatch> candidates = const [],
  }) =>
      PlaybackResolution._(failure: failure, candidates: candidates);

  factory PlaybackResolution.ambiguous(
    List<ProviderMatch> candidates, {
    ProviderException? failure,
  }) =>
      PlaybackResolution._(
        candidates: List.unmodifiable(candidates),
        failure: failure ??
            const ProviderException(
              ProviderErrorType.ambiguousProviderMatch,
              'Several provider titles match this one.',
            ),
      );

  bool get isSuccess => stream != null;
  bool get isAmbiguous => stream == null && candidates.isNotEmpty;
  ProviderErrorType get errorType => failure?.type ?? ProviderErrorType.unknown;
}

/// TMDB-to-provider orchestration: matching, typed results, short-lived stream
/// caching and concurrent-resolution protection.
///
/// Provider playback URLs are signed and short-lived, so they are cached for a
/// very short window only and dropped immediately when playback reports an
/// expiry/forbidden failure. Provider match metadata (subject id + detail path)
/// is safe to cache for much longer and avoids re-searching on every play.
///
/// Subtitle lists are cached separately, per provider match, season and
/// episode, so a subtitle retry never has to resolve the video again.
class StreamResolver {
  static const Duration streamTtl = Duration(minutes: 2);
  static const Duration matchTtl = Duration(hours: 12);
  static const Duration captionTtl = Duration(minutes: 10);

  /// Longest time stream resolution waits for subtitles. A slower subtitle
  /// lookup keeps running in the background and its result is cached.
  static const Duration captionBudget = Duration(seconds: 6);

  final ZarhostingService _service;
  final Map<String, _CachedMatch> _matchCache = {};
  final Map<String, _CachedStream> _streamCache = {};
  final Map<String, Future<PlaybackResolution>> _inFlight = {};
  final Map<String, _CachedCaptions> _captionCache = {};
  final Map<String, Future<CaptionLoad>> _captionInFlight = {};

  StreamResolver({ZarhostingService? service})
      : _service = service ?? ZarhostingService();

  ZarhostingService get providerService => _service;

  void clearCache() {
    _matchCache.clear();
    _streamCache.clear();
    _captionCache.clear();
  }

  /// Drops cached signed URLs for one title/episode after a playback failure.
  void invalidate({
    required MediaItem item,
    int season = 0,
    int episode = 0,
    bool dropMatch = false,
  }) {
    _streamCache.remove(_streamKey(item, season, episode));
    if (dropMatch) {
      _matchCache.remove(_matchKey(item));
      invalidateCaptions(item);
    }
  }

  /// Drops every cached subtitle list for a title, across all episodes.
  void invalidateCaptions(MediaItem item) {
    final prefix = '${item.mediaType}_${item.id}|';
    _captionCache.removeWhere((key, _) => key.startsWith(prefix));
  }

  Future<PlaybackResolution> resolve({
    required MediaItem item,
    ProviderMatch? providerMatch,
    int season = 0,
    int episode = 0,
    bool forceRefresh = false,
    void Function(ResolutionStage stage)? onStage,
  }) {
    final key = _streamKey(item, season, episode);

    if (!forceRefresh) {
      final cached = _streamCache[key];
      if (cached != null) {
        if (!cached.isExpired) {
          return Future.value(PlaybackResolution.success(cached.stream));
        }
        _streamCache.remove(key);
      }
      final pending = _inFlight[key];
      if (pending != null) return pending;
    }

    final future = _resolve(
      item: item,
      providerMatch: providerMatch,
      season: season,
      episode: episode,
      forceRefresh: forceRefresh,
      onStage: onStage,
    ).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// Subtitle discovery for one exact movie or episode.
  ///
  /// Returns cached results when fresh, joins an identical request already in
  /// flight, and otherwise asks the provider. With [budget] set, the wait is
  /// capped: a slower request resolves to [CaptionLoadStatus.pending] while
  /// the lookup keeps running and fills the cache for the next caller.
  Future<CaptionLoad> loadCaptions({
    required MediaItem item,
    required ProviderMatch match,
    int season = 0,
    int episode = 0,
    bool forceRefresh = false,
    Duration? budget,
  }) {
    final effectiveSeason = item.mediaType == 'tv' ? season : 0;
    final effectiveEpisode = item.mediaType == 'tv' ? episode : 0;
    final key = _captionKey(item, match, effectiveSeason, effectiveEpisode);
    final future = _captionFuture(
      key: key,
      item: item,
      match: match,
      season: effectiveSeason,
      episode: effectiveEpisode,
      forceRefresh: forceRefresh,
    );
    if (budget == null) return future;
    return future.timeout(budget, onTimeout: () => CaptionLoad.pending());
  }

  /// Subtitle discovery for a title that was already played or downloaded:
  /// reuses the known provider match and never resolves the video stream.
  /// Never throws; failures come back as a [CaptionLoad].
  Future<CaptionLoad> refreshCaptions({
    required MediaItem item,
    ProviderMatch? providerMatch,
    int season = 0,
    int episode = 0,
    bool forceRefresh = false,
    bool dropMatch = false,
  }) async {
    try {
      // An explicit match (the one that is playing or was downloaded) always
      // wins, so subtitles can never come from a different provider record.
      final matchResult = await _resolveMatch(
        item: item,
        explicit: providerMatch,
        forceRefresh: dropMatch,
      );
      final match = matchResult.match;
      if (match == null) {
        return CaptionLoad.failed(
          matchResult.asFailure ??
              const ProviderException(
                ProviderErrorType.noProviderMatch,
                'This title is not available on the provider.',
              ),
        );
      }
      return await loadCaptions(
        item: item,
        match: match,
        season: season,
        episode: episode,
        forceRefresh: forceRefresh,
      );
    } catch (error) {
      return CaptionLoad.failed(
        ProviderException(
          ProviderErrorType.unknown,
          'Subtitles are unavailable right now.',
          diagnostic: error.runtimeType.toString(),
        ),
      );
    }
  }

  Future<PlaybackResolution> _resolve({
    required MediaItem item,
    ProviderMatch? providerMatch,
    required int season,
    required int episode,
    required bool forceRefresh,
    void Function(ResolutionStage stage)? onStage,
  }) async {
    final effectiveSeason = item.mediaType == 'tv' ? season : 0;
    final effectiveEpisode = item.mediaType == 'tv' ? episode : 0;

    final hasKnownTarget = (providerMatch != null &&
            providerMatch.hasDistinctIdentifiers) ||
        ProviderMatch.fromMediaItem(item) != null;
    if (!hasKnownTarget) {
      onStage?.call(ResolutionStage.matchingProvider);
    }
    final matchResult = await _resolveMatch(
      item: item,
      explicit: providerMatch,
      forceRefresh: forceRefresh,
    );
    if (matchResult.isAmbiguous) {
      return PlaybackResolution.ambiguous(matchResult.candidates);
    }
    final match = matchResult.match;
    if (match == null) {
      return PlaybackResolution.failure(
        matchResult.asFailure ??
            const ProviderException(
              ProviderErrorType.noProviderMatch,
              'This title is not available on the provider.',
            ),
      );
    }

    onStage?.call(ResolutionStage.resolvingStream);
    // Subtitles are requested alongside the stream, never before it, and
    // waited for only up to captionBudget.
    final captionFuture = loadCaptions(
      item: item,
      match: match,
      season: effectiveSeason,
      episode: effectiveEpisode,
      forceRefresh: forceRefresh,
      budget: captionBudget,
    );
    try {
      final sources = await _service.resolveStreams(
        match: match,
        season: effectiveSeason,
        episode: effectiveEpisode,
      );
      if (sources.isEmpty) {
        return PlaybackResolution.failure(
          const ProviderException(
            ProviderErrorType.noPlayableSources,
            'The provider returned no playable source for this title.',
          ),
        );
      }
      final captionLoad = await captionFuture;

      final resolved = ResolvedMediaStream(
        sources: sources,
        captionLoad: captionLoad,
        match: match,
        mediaHeaders: ApiConstants.zarhostingMediaHeaders,
      );
      _streamCache[_streamKey(item, effectiveSeason, effectiveEpisode)] =
          _CachedStream(resolved);
      return PlaybackResolution.success(resolved);
    } on ProviderException catch (error) {
      if (error.invalidatesStream) {
        _streamCache.remove(_streamKey(item, effectiveSeason, effectiveEpisode));
      }
      return PlaybackResolution.failure(error);
    } on FormatException catch (error) {
      return PlaybackResolution.failure(
        ProviderException(
          ProviderErrorType.invalidProviderResponse,
          'The provider returned an unreadable stream response.',
          diagnostic: error.message,
        ),
      );
    } catch (error) {
      return PlaybackResolution.failure(
        ProviderException(
          ProviderErrorType.unknown,
          'Stream resolution failed unexpectedly.',
          diagnostic: error.runtimeType.toString(),
        ),
      );
    }
  }

  Future<CaptionLoad> _captionFuture({
    required String key,
    required MediaItem item,
    required ProviderMatch match,
    required int season,
    required int episode,
    required bool forceRefresh,
  }) {
    if (!forceRefresh) {
      final cached = _captionCache[key];
      if (cached != null) {
        if (DateTime.now().difference(cached.storedAt) < captionTtl) {
          return Future.value(cached.load);
        }
        _captionCache.remove(key);
      }
      final inFlight = _captionInFlight[key];
      if (inFlight != null) return inFlight;
    }

    late final Future<CaptionLoad> future;
    future = _fetchCaptions(
      key: key,
      item: item,
      match: match,
      season: season,
      episode: episode,
    ).whenComplete(() {
      // Clear only this request's own entry: a newer forced refresh may have
      // replaced it while this one was still running.
      if (identical(_captionInFlight[key], future)) {
        _captionInFlight.remove(key);
      }
    });
    _captionInFlight[key] = future;
    return future;
  }

  /// Never throws. Only fully loaded lists are cached: an empty or failed
  /// answer is re-checked on the next request rather than trusted.
  Future<CaptionLoad> _fetchCaptions({
    required String key,
    required MediaItem item,
    required ProviderMatch match,
    required int season,
    required int episode,
  }) async {
    CaptionLoad load;
    try {
      load = await _service.fetchCaptionLoad(
        match: match,
        season: season,
        episode: episode,
      );
    } on ProviderException catch (error) {
      load = CaptionLoad.failed(error);
    } catch (error) {
      load = CaptionLoad.failed(
        ProviderException(
          ProviderErrorType.unknown,
          'Subtitles are unavailable right now.',
          diagnostic: error.runtimeType.toString(),
        ),
      );
    }

    if (load.isLoaded) {
      _captionCache[key] = _CachedCaptions(load);
    } else {
      _captionCache.remove(key);
    }
    _recordCaptions(item, match, season, episode, load);
    return load;
  }

  void _recordCaptions(
    MediaItem item,
    ProviderMatch match,
    int season,
    int episode,
    CaptionLoad load,
  ) {
    DiagnosticsService.instance.record(
      scope: 'subtitles',
      operation: 'discover',
      failureType: load.failure?.type,
      data: {
        'tmdb': item.id,
        'mediaType': item.mediaType,
        'subject': match.subjectId,
        'detailPath': match.detailPath,
        'season': season,
        'episode': episode,
        'status': load.status.name,
        'shape': load.shape,
        'raw': load.rawCount,
        'tracks': load.tracks.length,
        'rejected': load.rejectedCount,
        'reasons': load.rejectionReasons.join('|'),
        'languages': load.tracks.map((track) => track.language).join(','),
        'http': load.failure?.statusCode ?? 0,
        'diag': load.failure?.diagnostic ?? '',
      },
    );
  }

  Future<ProviderMatchResult> _resolveMatch({
    required MediaItem item,
    ProviderMatch? explicit,
    required bool forceRefresh,
  }) async {
    if (explicit != null && explicit.hasDistinctIdentifiers) {
      return ProviderMatchResult.matched(explicit);
    }
    final fromItem = ProviderMatch.fromMediaItem(item);
    if (fromItem != null) return ProviderMatchResult.matched(fromItem);

    final key = _matchKey(item);
    if (!forceRefresh) {
      final cached = _matchCache[key];
      if (cached != null &&
          DateTime.now().difference(cached.storedAt) < matchTtl) {
        return ProviderMatchResult.matched(cached.match);
      }
      if (cached != null) _matchCache.remove(key);
    }

    final result = await _service.findMatch(
      title: item.title,
      originalTitle: item.originalTitle,
      year: item.releaseYear,
      isSeries: item.mediaType == 'tv',
    );
    if (result.isMatched) {
      _matchCache[key] = _CachedMatch(result.match!);
    }
    return result;
  }

  String _matchKey(MediaItem item) => '${item.mediaType}_${item.id}';

  String _streamKey(MediaItem item, int season, int episode) =>
      '${item.mediaType}_${item.id}_${season}_$episode';

  /// Includes the provider identity, so a changed provider match can never
  /// reuse subtitles fetched for a different record.
  String _captionKey(
    MediaItem item,
    ProviderMatch match,
    int season,
    int episode,
  ) =>
      '${item.mediaType}_${item.id}|${match.subjectId}|${match.detailPath}'
      '|s${season}e$episode';
}

class _CachedMatch {
  final ProviderMatch match;
  final DateTime storedAt;

  _CachedMatch(this.match) : storedAt = DateTime.now();
}

class _CachedStream {
  final ResolvedMediaStream stream;
  final DateTime storedAt;

  _CachedStream(this.stream) : storedAt = DateTime.now();

  bool get isExpired {
    if (stream.isExpired) return true;
    return DateTime.now().difference(storedAt) > StreamResolver.streamTtl;
  }
}

class _CachedCaptions {
  final CaptionLoad load;
  final DateTime storedAt;

  _CachedCaptions(this.load) : storedAt = DateTime.now();
}
