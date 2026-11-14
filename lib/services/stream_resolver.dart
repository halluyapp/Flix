import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../models/caption_track.dart';
import '../core/constants/api_constants.dart';
import 'zarhosting_service.dart';

class ResolvedMediaStream {
  final List<StreamSource> sources;
  final List<CaptionTrack> captions;
  final String providerTitle;
  final Map<String, String> mediaHeaders;
  final DateTime resolvedAt;

  ResolvedMediaStream({
    required this.sources,
    required this.captions,
    required this.providerTitle,
    required this.mediaHeaders,
    DateTime? resolvedAt,
  }) : resolvedAt = resolvedAt ?? DateTime.now();

  StreamSource? get bestSource =>
      selectableSources.isNotEmpty ? selectableSources.first : null;

  List<StreamSource> get selectableSources {
    final full = sources
        .where((s) => !s.isPreview && s.verifiedFullLength == true)
        .toList();
    final unverified = sources
        .where((s) => !s.isPreview && s.verifiedFullLength == null)
        .toList();
    final combined = [...full, ...unverified];
    return combined;
  }

  List<StreamSource> get downloadSources =>
      selectableSources.where((source) => source.isDownloadable).toList();
}

/// Resolves a TMDB title to playable Zarhosting sources.
///
/// Stream playback currently resolves directly against the provider and keeps
/// a short-lived in-memory cache so repeated playback does not re-run search
/// and stream endpoints. Provider URLs expire, so entries are dropped after
/// [cacheTtl] and failures are never cached.
class StreamResolver {
  // Provider playback URLs are signed and short-lived. Keep cached results
  // useful for quick episode/quality changes without replaying expired links.
  static const Duration cacheTtl = Duration(minutes: 10);

  final ZarhostingService _directService = ZarhostingService();
  final Map<String, ResolvedMediaStream> _memoryCache = {};

  void clearCache() => _memoryCache.clear();

  Future<ResolvedMediaStream?> resolve({
    required MediaItem item,
    ZarhostingTarget? providerTarget,
    int season = 0,
    int episode = 0,
    bool forceRefresh = false,
  }) async {
    final cacheKey = providerTarget == null
        ? '${item.id}_${item.mediaType}_${season}_$episode'
        : 'provider_${providerTarget.subjectId}_${season}_$episode';

    if (forceRefresh) _memoryCache.remove(cacheKey);
    final cached = _memoryCache[cacheKey];
    if (cached != null) {
      if (DateTime.now().difference(cached.resolvedAt) < cacheTtl) {
        return cached;
      }
      _memoryCache.remove(cacheKey);
    }

    final target = providerTarget ??
        await _directService.findMatch(
          title: item.title,
          year: item.releaseYear,
          isSeries: item.mediaType == 'tv',
        );

    if (target == null ||
        target.detailPath.trim().isEmpty ||
        target.detailPath == target.subjectId) return null;

    final sources = await _directService.resolveStreams(
      subjectId: target.subjectId,
      detailPath: target.detailPath,
      se: season,
      ep: episode,
    );

    if (sources.isEmpty) return null;

    final captions = await _directService.fetchCaptions(
      subjectId: target.subjectId,
      detailPath: target.detailPath,
      se: season,
      ep: episode,
    );

    final resolved = ResolvedMediaStream(
      sources: sources,
      captions: captions,
      providerTitle: target.title,
      mediaHeaders: ApiConstants.zarhostingMediaHeaders,
    );

    _memoryCache[cacheKey] = resolved;
    return resolved;
  }
}
