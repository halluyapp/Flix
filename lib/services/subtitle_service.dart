import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/constants/api_constants.dart';
import '../models/caption_track.dart';
import 'download_validation.dart';

class SubtitleCue {
  final Duration start;
  final Duration end;
  final String text;

  const SubtitleCue(
      {required this.start, required this.end, required this.text});
}

/// A validated subtitle file ready to be written next to its video.
class SubtitleFile {
  final String text;
  final String extension;
  final String language;
  final String languageName;
  final int sizeBytes;

  const SubtitleFile({
    required this.text,
    required this.extension,
    required this.language,
    required this.languageName,
    required this.sizeBytes,
  });
}

class SubtitleService {
  static const int maxSubtitleBytes = 8 * 1024 * 1024;

  static Future<List<SubtitleCue>> fetch(
    CaptionTrack track, {
    http.Client? client,
  }) async {
    return parse(await fetchText(track, client: client));
  }

  static Future<String> fetchText(
    CaptionTrack track, {
    http.Client? client,
  }) async {
    final uri = Uri.tryParse(track.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('This subtitle link is not valid.');
    }

    Object? lastError;
    final httpClient = client ?? http.Client();
    try {
      for (final profile in ApiConstants.zarhostingMediaHeaderProfiles) {
        try {
          final response = await httpClient
              .get(uri, headers: profile)
              .timeout(const Duration(seconds: 15));
          if (response.statusCode >= 200 && response.statusCode < 300) {
            if (response.bodyBytes.length > maxSubtitleBytes) {
              throw const FormatException('This subtitle file is too large.');
            }
            // Subtitle files are UTF-8 in practice; allowMalformed keeps a
            // stray legacy byte from breaking the whole track.
            final text = utf8
                .decode(response.bodyBytes, allowMalformed: true)
                .replaceFirst('\uFEFF', '')
                .trim();
            if (text.isEmpty) {
              throw const FormatException(
                  'The subtitle server returned an empty file.');
            }
            _rejectMarkup(text);
            return text;
          }
          if (![401, 403, 426, 428, 429].contains(response.statusCode)) {
            throw FormatException(
                'Subtitle server returned HTTP ${response.statusCode}.');
          }
          lastError = FormatException(
              'Subtitle server returned HTTP ${response.statusCode}.');
        } catch (error) {
          lastError = error;
        }
      }
    } finally {
      if (client == null) httpClient.close();
    }
    throw FormatException(
        'The selected subtitle could not be loaded: '
        '${lastError is FormatException ? lastError.message : 'network error'}');
  }

  /// Downloads and validates a subtitle, rejecting HTML/error pages and files
  /// with no readable cues so a broken subtitle is never reported as saved.
  static Future<SubtitleFile> fetchValidated(
    CaptionTrack track, {
    http.Client? client,
  }) async {
    final text = await fetchText(track, client: client);
    final cues = parse(text);
    if (cues.isEmpty) {
      throw const FormatException(
        'This subtitle file has no readable captions.',
      );
    }
    final extension = DownloadValidation.subtitleExtension(track.url, text);
    return SubtitleFile(
      text: text,
      extension: extension,
      language: track.language,
      languageName: track.languageName,
      sizeBytes: utf8.encode(text).length,
    );
  }

  static void _rejectMarkup(String text) {
    final prefix = text.trimLeft();
    if (DownloadValidation.looksLikeMarkup(prefix)) {
      throw const FormatException(
          'The subtitle server returned a web page instead of subtitles.');
    }
  }

  static List<SubtitleCue> parse(String raw) {
    final normalized =
        raw.replaceAll('\r', '').replaceFirst(RegExp(r'^\uFEFF'), '');
    final blocks = normalized.split(RegExp(r'\n\s*\n'));
    final cues = <SubtitleCue>[];
    final timestamp = RegExp(
      r'((?:\d{1,2}:)?\d{2}:\d{2}[,.]\d{3})\s*-->\s*((?:\d{1,2}:)?\d{2}:\d{2}[,.]\d{3})',
    );

    for (final block in blocks) {
      final lines = block.split('\n');
      final timingIndex = lines.indexWhere((line) => timestamp.hasMatch(line));
      if (timingIndex < 0) continue;
      final match = timestamp.firstMatch(lines[timingIndex]);
      if (match == null) continue;
      final start = _parseTimestamp(match.group(1)!);
      final end = _parseTimestamp(match.group(2)!);
      if (end <= start) continue;
      final text = lines
          .skip(timingIndex + 1)
          .join('\n')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&nbsp;', ' ')
          .trim();
      if (text.isNotEmpty) {
        cues.add(SubtitleCue(start: start, end: end, text: text));
      }
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static Duration _parseTimestamp(String value) {
    final parts = value.replaceAll(',', '.').split(':');
    final secondsParts = parts.last.split('.');
    final seconds = int.tryParse(secondsParts[0]) ?? 0;
    final milliseconds = int.tryParse(secondsParts.length > 1
            ? secondsParts[1].padRight(3, '0').substring(0, 3)
            : '0') ??
        0;
    final minutes =
        parts.length >= 2 ? int.tryParse(parts[parts.length - 2]) ?? 0 : 0;
    final hours =
        parts.length >= 3 ? int.tryParse(parts[parts.length - 3]) ?? 0 : 0;
    return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: milliseconds);
  }

  static String activeText(List<SubtitleCue> cues, Duration position) {
    var low = 0;
    var high = cues.length - 1;
    final milliseconds = position.inMilliseconds;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      final cue = cues[mid];
      if (milliseconds < cue.start.inMilliseconds) {
        high = mid - 1;
      } else if (milliseconds >= cue.end.inMilliseconds) {
        low = mid + 1;
      } else {
        return cue.text;
      }
    }
    return '';
  }
}
