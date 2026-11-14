import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants/api_constants.dart';
import '../models/stream_source.dart';
import '../models/caption_track.dart';

class ZarhostingTarget {
  final String subjectId;
  final String detailPath;
  final String title;
  final int year;
  final bool isSeries;

  ZarhostingTarget({
    required this.subjectId,
    required this.detailPath,
    required this.title,
    required this.year,
    required this.isSeries,
  });
}

class ZarhostingService {
  static String normalizeTitle(String raw) {
    return raw
        .toLowerCase()
        .replaceAll("'", "")
        .replaceAll('"', '')
        .replaceAll(RegExp(r'[\s\-_:,.!?\(\)\[\]]+'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
        .trim();
  }

  /// Provider titles often carry a language badge or a season suffix
  /// ("Breaking Bad [Hindi] S5"). Strip those before comparing so a season
  /// entry still matches its TMDB series.
  static String _comparisonTitle(String raw) {
    var t = raw.replaceAll(RegExp(r'\[(?:[^\]]*)\]'), ' ');
    t = t.replaceAll(RegExp(r'\((?:[^)]*)\)'), ' ');
    t = t.replaceAll(RegExp(r'\b(?:s\d{1,2}|season\s?\d{1,2})\b', caseSensitive: false), ' ');
    return normalizeTitle(t);
  }

  static double calculateSimilarity(String s1, String s2) {
    final n1 = normalizeTitle(s1);
    final n2 = normalizeTitle(s2);
    if (n1 == n2) return 1.0;
    if (n1.isEmpty || n2.isEmpty) return 0.0;
    if (n1.contains(n2) || n2.contains(n1)) return 0.85;

    final words1 = n1.split(' ').where((w) => w.length > 1).toSet();
    final words2 = n2.split(' ').where((w) => w.length > 1).toSet();
    if (words1.isEmpty || words2.isEmpty) return 0.0;

    int matches = 0;
    for (final w in words1) {
      if (words2.contains(w)) matches++;
    }
    return (2.0 * matches) / (words1.length + words2.length);
  }

  Future<ZarhostingTarget?> findMatch({
    required String title,
    required int year,
    required bool isSeries,
  }) async {
    try {
      final cleanTitle = title.trim();
      if (cleanTitle.isEmpty) return null;

      final url = Uri.parse(
        '${ApiConstants.zarhostingBaseUrl}/search?q=${Uri.encodeComponent(cleanTitle)}&page=1&per_page=30',
      );

      final res = await http.get(url, headers: ApiConstants.zarhostingApiHeaders).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;

      final data = json.decode(res.body);
      final rawData = (data is Map && data['data'] != null) ? data['data'] : data;
      final rawList = rawData is Map
          ? (rawData['items'] ?? rawData['results'] ?? [])
          : (rawData is List ? rawData : []);

      if (rawList is! List || rawList.isEmpty) return null;

      ZarhostingTarget? bestCandidate;
      double highestScore = 0.0;

      for (final rawItem in rawList) {
        if (rawItem is! Map) continue;
        final item = rawItem.cast<String, dynamic>();

        final itemTitle = (item['title'] ?? item['name'] ?? item['subject_title'] ?? '').toString();
        final subjectId = (item['subject_id'] ?? item['subjectId'] ?? item['id'] ?? '').toString();
        // The stream endpoint only answers when detail_path is the provider
        // slug; passing the subject id there returns HTTP 502.
        final detailPath = (item['detail_path'] ?? item['detailPath'] ?? item['slug'] ?? '').toString();

        if (subjectId.isEmpty) continue;

        final itemYearStr = (item['year'] ?? item['release_year'] ?? item['release_date'] ?? '').toString();
        final itemYear = int.tryParse(itemYearStr.length >= 4 ? itemYearStr.substring(0, 4) : itemYearStr) ?? 0;

        final itemType = (item['type'] ?? item['subject_type'] ?? '').toString().toLowerCase();
        final hasSeasons = item['seasons'] is List && (item['seasons'] as List).isNotEmpty;
        final itemIsSeries = itemType == 'tv' || itemType == 'series' || itemType == '2' || hasSeasons;

        // Discard opposing media type
        if (itemIsSeries != isSeries) {
          continue;
        }

        final baseTitle = (item['base_title'] ?? item['baseTitle'] ?? '').toString();
        final sim = [
          calculateSimilarity(title, itemTitle),
          if (baseTitle.isNotEmpty) calculateSimilarity(title, baseTitle),
          calculateSimilarity(_comparisonTitle(title), _comparisonTitle(itemTitle)),
        ].reduce((a, b) => a > b ? a : b);
        if (sim < 0.55) continue;

        double score = sim * 100.0;

        // Year alignment weighting. Series season entries are dated by season
        // release year, so they get a wider tolerance than movies.
        if (year > 0 && itemYear > 0) {
          final diff = (year - itemYear).abs();
          if (diff == 0) {
            score += 25.0;
          } else if (diff <= 1) {
            score += 15.0;
          } else if (diff > (isSeries ? 8 : 2)) {
            score -= 20.0;
          }
        }

        if (score > highestScore) {
          highestScore = score;
          bestCandidate = ZarhostingTarget(
            subjectId: subjectId,
            detailPath: detailPath.isNotEmpty ? detailPath : subjectId,
            title: itemTitle,
            year: itemYear,
            isSeries: itemIsSeries,
          );
        }
      }

      // Rejection threshold for ambiguous/unrelated results
      if (highestScore >= 60.0) {
        return bestCandidate;
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

      final res = await http.get(Uri.parse(endpoint), headers: ApiConstants.zarhostingApiHeaders).timeout(const Duration(seconds: 18));
      if (res.statusCode != 200) return [];

      final data = json.decode(res.body);
      final body = (data is Map && data['data'] is Map) ? data['data'] : (data is Map ? data : {});

      final sourcesList = (body['sources'] ?? body['streams'] ?? []) as List;
      final List<StreamSource> sources = [];
      final Set<String> seenUrls = {};

      for (final s in sourcesList) {
        if (s is Map) {
          final map = s.cast<String, dynamic>();
          // vip_locked sources are rejected by the CDN at playback time.
          if (map['vip_locked'] == true) continue;
          final src = StreamSource.fromJson(map);
          if (src.url.startsWith('https://') && !src.isPreview && !seenUrls.contains(src.url)) {
            seenUrls.add(src.url);
            sources.add(src);
          }
        }
      }

      // Append adaptive manifests (HLS first, then DASH) when the provider
      // exposes them.
      for (final entry in [
        ...((body['hls'] ?? []) as List).map((h) => MapEntry(h, 'HLS')),
        ...((body['dash'] ?? []) as List).map((d) => MapEntry(d, 'DASH')),
      ]) {
        final u = entry.key.toString();
        if (u.startsWith('https://') && !seenUrls.contains(u)) {
          seenUrls.add(u);
          sources.add(StreamSource(
            url: u,
            resolution: 'Auto (${entry.value})',
            qualityValue: 1080,
            format: entry.value,
            sizeBytes: 0,
            durationSeconds: 0,
            isPreview: false,
          ));
        }
      }

      // Sort: MP4 first, then descending quality
      sources.sort((a, b) {
        final fa = a.format.toUpperCase() == 'MP4' ? 0 : 1;
        final fb = b.format.toUpperCase() == 'MP4' ? 0 : 1;
        if (fa != fb) return fa.compareTo(fb);
        return b.qualityValue.compareTo(a.qualityValue);
      });

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
      final Set<String> seen = {};

      for (final c in captionsList) {
        if (c is Map) {
          final track = CaptionTrack.fromJson(c.cast<String, dynamic>());
          if (track.url.startsWith('https://') && !seen.contains(track.url)) {
            seen.add(track.url);
            tracks.add(track);
          }
        }
      }
      return tracks;
    } catch (_) {
      return [];
    }
  }
}
