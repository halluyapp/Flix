import 'dart:convert';
import 'package:http/http.dart' as http;
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
  final bool isCached;

  ResolvedMediaStream({
    required this.sources,
    required this.captions,
    required this.providerTitle,
    required this.mediaHeaders,
    this.isCached = false,
  });

  StreamSource? get bestSource => sources.isNotEmpty ? sources.first : null;

  List<StreamSource> get selectableSources {
    final full = sources.where((s) => !s.isPreview && s.verifiedFullLength == true).toList();
    final unverified = sources.where((s) => !s.isPreview && s.verifiedFullLength == null).toList();
    final combined = [...full, ...unverified];
    return combined.isNotEmpty ? combined : sources;
  }
}

class StreamResolver {
  final ZarhostingService _directService = ZarhostingService();
  final Map<String, ResolvedMediaStream> _memoryCache = {};

  Future<ResolvedMediaStream?> resolve({
    required MediaItem item,
    int season = 0,
    int episode = 0,
  }) async {
    final cacheKey = '${item.id}_${item.mediaType}_${season}_$episode';
    if (_memoryCache.containsKey(cacheKey)) {
      return _memoryCache[cacheKey];
    }

    // 1. Try Cloud Edge Function Stream Resolver
    try {
      if (ApiConstants.streamResolverUrl.isNotEmpty &&
          !ApiConstants.streamResolverUrl.contains('placeholder')) {
        final res = await http.post(
          Uri.parse(ApiConstants.streamResolverUrl),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'tmdbId': item.id,
            'title': item.title,
            'year': item.releaseYear,
            'isSeries': item.mediaType == 'tv',
            'season': season,
            'episode': episode,
          }),
        ).timeout(const Duration(seconds: 12));

        if (res.statusCode == 200) {
          final data = json.decode(res.body);
          final rawSources = (data['sources'] as List? ?? []);
          final rawCaps = (data['captions'] as List? ?? []);

          final sources = rawSources
              .whereType<Map>()
              .map((s) => StreamSource.fromJson(s.cast<String, dynamic>()))
              .toList();

          final captions = rawCaps
              .whereType<Map>()
              .map((c) => CaptionTrack.fromJson(c.cast<String, dynamic>()))
              .toList();

          if (sources.isNotEmpty) {
            final resolved = ResolvedMediaStream(
              sources: sources,
              captions: captions,
              providerTitle: (data['title'] ?? item.title).toString(),
              mediaHeaders: ApiConstants.zarhostingMediaHeaders,
              isCached: data['cached'] == true,
            );
            _memoryCache[cacheKey] = resolved;
            return resolved;
          }
        }
      }
    } catch (_) {
      // Edge function failed or offline, fall back to direct resolver
    }

    // 2. Direct Zarhosting Client Fallback
    final target = await _directService.findMatch(
      title: item.title,
      year: item.releaseYear,
      isSeries: item.mediaType == 'tv',
    );

    if (target == null) return null;

    final sources = await _directService.resolveStreams(
      subjectId: target.subjectId,
      detailPath: target.detailPath,
      se: season,
      ep: episode,
    );

    final captions = await _directService.fetchCaptions(
      subjectId: target.subjectId,
      detailPath: target.detailPath,
      se: season,
      ep: episode,
    );

    if (sources.isEmpty) return null;

    final resolved = ResolvedMediaStream(
      sources: sources,
      captions: captions,
      providerTitle: target.title,
      mediaHeaders: ApiConstants.zarhostingMediaHeaders,
      isCached: false,
    );

    _memoryCache[cacheKey] = resolved;
    return resolved;
  }
}
