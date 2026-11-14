import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants/api_constants.dart';
import '../models/stream_source.dart';
import '../models/caption_track.dart';

class ZarhostingTarget {
  final String subjectId;
  final String detailPath;
  final String title;

  ZarhostingTarget({
    required this.subjectId,
    required this.detailPath,
    required this.title,
  });
}

class ZarhostingService {
  Future<ZarhostingTarget?> findMatch({
    required String title,
    required int year,
    required bool isSeries,
  }) async {
    try {
      final url = Uri.parse('${ApiConstants.zarhostingBaseUrl}/search?q=${Uri.encodeComponent(title)}&page=1&per_page=15');
      final res = await http.get(url, headers: ApiConstants.zarhostingApiHeaders).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;

      final data = json.decode(res.body);
      final rawItems = data['items'] ?? (data['data'] != null ? data['data']['items'] : null) ?? [];
      if (rawItems is! List || rawItems.isEmpty) return null;

      final normalizedQuery = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

      for (final item in rawItems) {
        if (item is! Map) continue;
        final itemTitle = (item['title'] ?? item['name'] ?? '').toString();
        final normItem = itemTitle.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        final subjectId = (item['subject_id'] ?? item['subjectId'] ?? '').toString();
        final detailPath = (item['detail_path'] ?? item['detailPath'] ?? '').toString();

        if (subjectId.isNotEmpty && detailPath.isNotEmpty) {
          if (normItem.contains(normalizedQuery) || normalizedQuery.contains(normItem)) {
            return ZarhostingTarget(
              subjectId: subjectId,
              detailPath: detailPath,
              title: itemTitle,
            );
          }
        }
      }

      // Fallback: take first item if present
      final first = rawItems.first;
      if (first is Map) {
        final subjectId = (first['subject_id'] ?? first['subjectId'] ?? '').toString();
        final detailPath = (first['detail_path'] ?? first['detailPath'] ?? '').toString();
        if (subjectId.isNotEmpty && detailPath.isNotEmpty) {
          return ZarhostingTarget(
            subjectId: subjectId,
            detailPath: detailPath,
            title: (first['title'] ?? '').toString(),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<StreamSource>> resolveStreams({
    required String subjectId,
    required String detailPath,
    int se = 0,
    int ep = 0,
  }) async {
    try {
      final endpoint = '${ApiConstants.zarhostingBaseUrl}/stream/${Uri.encodeComponent(subjectId)}'
          '?detail_path=${Uri.encodeComponent(detailPath)}&se=$se&ep=$ep';
      final res = await http.get(Uri.parse(endpoint), headers: ApiConstants.zarhostingApiHeaders).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];

      final data = json.decode(res.body);
      final body = (data is Map && data['data'] is Map) ? data['data'] : (data is Map ? data : {});
      final sourcesList = (body['sources'] ?? body['streams'] ?? []) as List;

      final List<StreamSource> sources = [];
      for (final s in sourcesList) {
        if (s is Map<String, dynamic>) {
          final src = StreamSource.fromJson(s);
          if (src.url.startsWith('https://') && !src.isPreview) {
            sources.add(src);
          }
        }
      }

      // Add HLS / DASH manifests if available
      final hlsList = (body['hls'] ?? []) as List;
      for (final h in hlsList) {
        if (h is String && h.startsWith('https://')) {
          sources.add(StreamSource(
            url: h,
            resolution: 'Auto (HLS)',
            qualityValue: 1080,
            format: 'HLS',
            sizeBytes: 0,
            durationSeconds: 0,
            isPreview: false,
          ));
        }
      }

      // Sort highest quality first
      sources.sort((a, b) => b.qualityValue.compareTo(a.qualityValue));
      return sources;
    } catch (_) {
      return [];
    }
  }

  Future<List<CaptionTrack>> fetchCaptions({
    required String subjectId,
    required String detailPath,
    int se = 0,
    int ep = 0,
  }) async {
    try {
      final endpoint = '${ApiConstants.zarhostingBaseUrl}/stream/${Uri.encodeComponent(subjectId)}/captions'
          '?detail_path=${Uri.encodeComponent(detailPath)}&se=$se&ep=$ep';
      final res = await http.get(Uri.parse(endpoint), headers: ApiConstants.zarhostingApiHeaders).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];

      final data = json.decode(res.body);
      final body = (data is Map && data['data'] is Map) ? data['data'] : (data is Map ? data : {});
      final captionsList = (body['captions'] ?? body['subtitles'] ?? []) as List;

      final List<CaptionTrack> tracks = [];
      for (final c in captionsList) {
        if (c is Map<String, dynamic>) {
          tracks.add(CaptionTrack.fromJson(c));
        }
      }
      return tracks;
    } catch (_) {
      return [];
    }
  }
}
