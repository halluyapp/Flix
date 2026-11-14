import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../models/caption_track.dart';
import 'zarhosting_service.dart';

class ResolvedMediaStream {
  final List<StreamSource> sources;
  final List<CaptionTrack> captions;
  final String providerTitle;

  ResolvedMediaStream({
    required this.sources,
    required this.captions,
    required this.providerTitle,
  });

  StreamSource? get bestSource => sources.isNotEmpty ? sources.first : null;
}

class StreamResolver {
  final ZarhostingService _zarhostingService = ZarhostingService();
  final Map<String, ResolvedMediaStream> _localCache = {};

  Future<ResolvedMediaStream?> resolve({
    required MediaItem item,
    int season = 0,
    int episode = 0,
  }) async {
    final cacheKey = '${item.id}_${item.mediaType}_${season}_$episode';
    if (_localCache.containsKey(cacheKey)) {
      return _localCache[cacheKey];
    }

    final target = await _zarhostingService.findMatch(
      title: item.title,
      year: item.releaseYear,
      isSeries: item.mediaType == 'tv',
    );

    if (target == null) return null;

    final sources = await _zarhostingService.resolveStreams(
      subjectId: target.subjectId,
      detailPath: target.detailPath,
      se: season,
      ep: episode,
    );

    final captions = await _zarhostingService.fetchCaptions(
      subjectId: target.subjectId,
      detailPath: target.detailPath,
      se: season,
      ep: episode,
    );

    final resolved = ResolvedMediaStream(
      sources: sources,
      captions: captions,
      providerTitle: target.title,
    );

    if (sources.isNotEmpty) {
      _localCache[cacheKey] = resolved;
    }

    return resolved;
  }
}
