import '../core/constants/api_constants.dart';
import '../core/provider/provider_failures.dart';
import '../models/caption_track.dart';
import '../models/media_item.dart';
import '../models/provider_match.dart';
import '../models/stream_source.dart';
import 'zarhosting_service.dart';

/// A successfully resolved playback session.
class ResolvedMediaStream {
  final List<StreamSource> sources;
  final List<CaptionTrack> captions;
  final ProviderMatch match;
  final Map<String, String> mediaHeaders;
  final DateTime resolvedAt;
  final DateTime? expiresAt;

  ResolvedMediaStream({
    required this.sources,
    required this.captions,
    required this.match,
    required this.mediaHeaders,
    DateTime? resolvedAt,
    this.expiresAt,
  }) : resolvedAt = resolvedAt ?? DateTime.now();

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
class StreamResolver {
  static const Duration streamTtl = Duration(minutes: 2);
  static const Duration matchTtl = Duration(hours: 12);

  final ZarhostingService _service;
  final Map<String, _CachedMatch> _matchCache = {};
  final Map<String, _CachedStream> _streamCache = {};
  final Map<String, Future<PlaybackResolution>> _inFlight = {};

  StreamResolver({ZarhostingService? service})
      : _service = service ?? ZarhostingService();

  ZarhostingService get providerService => _service;

  void clearCache() {
    _matchCache.clear();
    _streamCache.clear();
  }

  /// Drops cached signed URLs for one title/episode after a playback failure.
  void invalidate({
    required MediaItem item,
    int season = 0,
    int episode = 0,
    bool dropMatch = false,
  }) {
    _streamCache.remove(_streamKey(item, season, episode));
    if (dropMatch) _matchCache.remove(_matchKey(item));
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
      final captions = await _service.fetchCaptions(
        match: match,
        season: effectiveSeason,
        episode: effectiveEpisode,
      );

      final resolved = ResolvedMediaStream(
        sources: sources,
        captions: captions,
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
