import 'package:http/http.dart' as http;

import '../core/constants/api_constants.dart';
import '../models/caption_track.dart';

class SubtitleCue {
  final Duration start;
  final Duration end;
  final String text;

  const SubtitleCue(
      {required this.start, required this.end, required this.text});
}

class SubtitleService {
  static Future<List<SubtitleCue>> fetch(CaptionTrack track) async {
    return parse(await fetchText(track));
  }

  static Future<String> fetchText(CaptionTrack track) async {
    final uri = Uri.tryParse(track.url);
    if (uri == null || uri.scheme != 'https') {
      throw const FormatException('This subtitle link is not valid.');
    }

    Object? lastError;
    for (final profile in ApiConstants.zarhostingMediaHeaderProfiles) {
      try {
        final response = await http
            .get(uri, headers: profile)
            .timeout(const Duration(seconds: 15));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final body = response.body.trim();
          if (body.isEmpty) return '';
          return body;
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
    throw FormatException(
        'The selected subtitle could not be loaded: $lastError');
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
      if (text.isNotEmpty)
        cues.add(SubtitleCue(start: start, end: end, text: text));
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
