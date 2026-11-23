import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/constants/api_constants.dart';
import '../models/caption_track.dart';
import 'diagnostics_service.dart';

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

  /// Real format of the content: `srt`, `vtt` or `ass`.
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

/// Why a subtitle file could not be fetched or validated.
enum SubtitleFailure {
  invalidLink,
  accessDenied,
  expired,
  notFound,
  rateLimited,
  serverError,
  httpStatus,
  timeout,
  network,
  invalidContent,
  unsupportedFormat,
  tooLarge,
}

/// Typed subtitle failure. [message] is user-safe and never contains the
/// signed URL.
class SubtitleException implements Exception {
  final SubtitleFailure failure;
  final String message;
  final int? statusCode;

  const SubtitleException(this.failure, this.message, {this.statusCode});

  /// True when a fresh caption list from the provider may fix the problem.
  bool get needsFreshLink =>
      failure == SubtitleFailure.accessDenied ||
      failure == SubtitleFailure.expired;

  @override
  String toString() => message;
}

/// Downloads, validates and parses subtitle files.
///
/// Media headers are used for every subtitle request, never the JSON API
/// headers. Retries are bounded: one repeat for a transient server or network
/// error, then at most one attempt per media header profile for access
/// failures, all within a fixed overall budget.
class SubtitleService {
  static const int maxSubtitleBytes = 8 * 1024 * 1024;
  static const Duration requestTimeout = Duration(seconds: 12);
  static const Duration totalBudget = Duration(seconds: 30);

  static final RegExp _timingLine =
      RegExp(r'(?:\d{1,2}:)?\d{2}:\d{2}[,.]\d{3}\s*-->');
  static final RegExp _assDialogue =
      RegExp(r'^dialogue:', multiLine: true, caseSensitive: false);

  static Future<List<SubtitleCue>> fetch(
    CaptionTrack track, {
    http.Client? client,
  }) async {
    return parseText(await fetchText(track, client: client));
  }

  /// Fetches the raw subtitle text, decoded and checked for transport-level
  /// problems. Throws [SubtitleException] for every failure.
  static Future<String> fetchText(
    CaptionTrack track, {
    http.Client? client,
  }) async {
    final uri = _validatedUri(track);
    final httpClient = client ?? http.Client();
    final deadline = DateTime.now().add(totalBudget);
    SubtitleException? lastFailure;
    try {
      for (final profile in ApiConstants.movieboxMediaHeaderProfiles) {
        if (DateTime.now().isAfter(deadline)) break;
        try {
          return await _getWithRetry(httpClient, uri, profile);
        } on SubtitleException catch (error) {
          lastFailure = error;
          if (!_tryNextProfile(error.failure)) break;
        }
      }
    } finally {
      if (client == null) httpClient.close();
    }

    final failure = lastFailure ??
        const SubtitleException(
          SubtitleFailure.network,
          'Flix could not reach the subtitle server.',
        );
    DiagnosticsService.instance.record(
      scope: 'subtitles',
      operation: 'fetch',
      data: {
        'language': track.language,
        'host': track.host,
        'kind': failure.failure.name,
        'status': failure.statusCode ?? 0,
      },
    );
    throw failure;
  }

  /// Downloads and validates a subtitle. Rejects HTML pages, empty files,
  /// files with no readable cues and formats Flix cannot display. The saved
  /// extension always reflects the content, never a guessed `.srt`.
  static Future<SubtitleFile> fetchValidated(
    CaptionTrack track, {
    http.Client? client,
  }) async {
    final text = await fetchText(track, client: client);
    final format = detectFormat(text);
    if (format.isEmpty) {
      throw const SubtitleException(
        SubtitleFailure.invalidContent,
        'This subtitle file has no readable captions.',
      );
    }
    if (format == 'ttml' || format == 'xml') {
      throw const SubtitleException(
        SubtitleFailure.unsupportedFormat,
        'This subtitle format (TTML) is not supported yet.',
      );
    }
    if (parseText(text).isEmpty) {
      throw const SubtitleException(
        SubtitleFailure.invalidContent,
        'This subtitle file has no readable captions.',
      );
    }
    return SubtitleFile(
      text: text,
      extension: format,
      language: track.language,
      languageName: track.languageName,
      sizeBytes: utf8.encode(text).length,
    );
  }

  static Uri _validatedUri(CaptionTrack track) {
    if (track.rejectionReason != null) {
      throw const SubtitleException(
        SubtitleFailure.invalidLink,
        'This subtitle link is not valid.',
      );
    }
    return Uri.parse(track.url.trim());
  }

  static bool _tryNextProfile(SubtitleFailure failure) =>
      failure == SubtitleFailure.accessDenied ||
      failure == SubtitleFailure.rateLimited ||
      failure == SubtitleFailure.invalidContent ||
      failure == SubtitleFailure.httpStatus;

  static Future<String> _getWithRetry(
    http.Client client,
    Uri uri,
    Map<String, String> profile,
  ) async {
    SubtitleException? failure;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      try {
        final response =
            await client.get(uri, headers: profile).timeout(requestTimeout);
        return _readResponse(response);
      } on SubtitleException catch (error) {
        failure = error;
        // Only server errors are worth a second try on the same profile.
        if (error.failure != SubtitleFailure.serverError) break;
      } on TimeoutException {
        failure = const SubtitleException(
          SubtitleFailure.timeout,
          'The subtitle server did not respond in time.',
        );
      } on SocketException {
        failure = const SubtitleException(
          SubtitleFailure.network,
          'Flix could not reach the subtitle server.',
        );
      } on http.ClientException {
        failure = const SubtitleException(
          SubtitleFailure.network,
          'Flix could not reach the subtitle server.',
        );
      } on Exception {
        failure = const SubtitleException(
          SubtitleFailure.network,
          'Flix could not reach the subtitle server.',
        );
      }
    }
    throw failure ??
        const SubtitleException(
          SubtitleFailure.network,
          'Flix could not reach the subtitle server.',
        );
  }

  static String _readResponse(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      final bytes = _decompress(response);
      if (bytes.length > maxSubtitleBytes) {
        throw const SubtitleException(
          SubtitleFailure.tooLarge,
          'This subtitle file is too large.',
        );
      }
      final contentType =
          (response.headers['content-type'] ?? '').toLowerCase();
      final text = decodeBytes(bytes);
      if (text.isEmpty) {
        throw const SubtitleException(
          SubtitleFailure.invalidContent,
          'This subtitle file is empty.',
        );
      }
      if (contentType.contains('text/html') || _isHtml(text)) {
        throw const SubtitleException(
          SubtitleFailure.invalidContent,
          'The subtitle server returned a web page instead of subtitles.',
        );
      }
      return text;
    }

    const refreshHint = 'Retry subtitles to get a fresh link.';
    if (status == 401 || status == 403) {
      final body = utf8
          .decode(response.bodyBytes.take(2048).toList(), allowMalformed: true)
          .toLowerCase();
      // A 401 means the signed link is no longer accepted: a fresh provider
      // list can fix that. A 403 is a refusal a new link will not fix, unless
      // the body says the link expired.
      if (status == 401 || body.contains('expir')) {
        throw SubtitleException(
          SubtitleFailure.expired,
          'This subtitle link has expired. $refreshHint',
          statusCode: status,
        );
      }
      throw SubtitleException(
        SubtitleFailure.accessDenied,
        'The subtitle server refused this link. $refreshHint',
        statusCode: status,
      );
    }
    if (status == 426 || status == 428) {
      throw SubtitleException(
        SubtitleFailure.accessDenied,
        'The subtitle server refused this request.',
        statusCode: status,
      );
    }
    if (status == 404) {
      throw SubtitleException(
        SubtitleFailure.notFound,
        'This subtitle is no longer available.',
        statusCode: status,
      );
    }
    if (status == 410) {
      throw SubtitleException(
        SubtitleFailure.expired,
        'This subtitle link has expired. $refreshHint',
        statusCode: status,
      );
    }
    if (status == 429) {
      throw SubtitleException(
        SubtitleFailure.rateLimited,
        'The subtitle server is rate-limiting requests. Try again shortly.',
        statusCode: status,
      );
    }
    if (status >= 500) {
      throw SubtitleException(
        SubtitleFailure.serverError,
        'The subtitle server is temporarily unavailable.',
        statusCode: status,
      );
    }
    throw SubtitleException(
      SubtitleFailure.httpStatus,
      'The subtitle server returned HTTP $status.',
      statusCode: status,
    );
  }

  static List<int> _decompress(http.Response response) {
    final bytes = response.bodyBytes;
    final encoding = (response.headers['content-encoding'] ?? '').toLowerCase();
    final looksGzipped =
        bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
    if (encoding.contains('gzip') || looksGzipped) {
      try {
        return gzip.decode(bytes);
      } catch (_) {
        return bytes;
      }
    }
    return bytes;
  }

  /// Decodes subtitle bytes: UTF-8 (with or without BOM), UTF-16 with a BOM,
  /// and tolerant of stray legacy bytes so one bad byte never breaks a track.
  static String decodeBytes(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
    final start = bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF
        ? 3
        : 0;
    return utf8
        .decode(bytes.sublist(start), allowMalformed: true)
        .replaceFirst('\uFEFF', '')
        .trim();
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    // Combine surrogate pairs so characters outside the BMP survive.
    final codePoints = <int>[];
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xD800 &&
          unit <= 0xDBFF &&
          i + 1 < units.length &&
          units[i + 1] >= 0xDC00 &&
          units[i + 1] <= 0xDFFF) {
        codePoints.add(0x10000 + ((unit - 0xD800) << 10) + (units[i + 1] - 0xDC00));
        i++;
      } else {
        codePoints.add(unit);
      }
    }
    return String.fromCharCodes(codePoints)
        .replaceFirst('\uFEFF', '')
        .trim();
  }

  static bool _isHtml(String text) {
    final head = text.trimLeft();
    final sample =
        (head.length > 256 ? head.substring(0, 256) : head).toLowerCase();
    return sample.startsWith('<!doctype html') ||
        sample.startsWith('<html') ||
        sample.startsWith('<head') ||
        sample.startsWith('<body') ||
        sample.contains('<html');
  }

  /// Identifies the subtitle format from its content. Returns `vtt`, `srt`,
  /// `ass`, `ttml` (or `xml` for an unrecognised XML document), or '' when the
  /// text is not a subtitle at all.
  static String detectFormat(String text) {
    final head = text.trimLeft();
    if (head.startsWith('WEBVTT')) return 'vtt';
    final sample = head.length > 8192 ? head.substring(0, 8192) : head;
    final lower = sample.toLowerCase();
    if (lower.contains('[script info]') ||
        (lower.contains('[events]') && _assDialogue.hasMatch(sample))) {
      return 'ass';
    }
    if (lower.contains('<tt ') ||
        lower.contains('<tt>') ||
        lower.contains('ns/ttml')) {
      return 'ttml';
    }
    if (lower.startsWith('<?xml')) return 'xml';
    if (_timingLine.hasMatch(text)) return 'srt';
    return '';
  }

  /// Parses any supported format by its content.
  static List<SubtitleCue> parseText(String text) {
    final format = detectFormat(text);
    if (format == 'ass' || format == 'ssa') return parseAss(text);
    return parse(text);
  }

  /// Parses SRT and WebVTT timestamp cues.
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

  /// Parses SubStation Alpha / Advanced SubStation (`[Events]` Dialogue
  /// lines), honouring the `Format:` field order and stripping style
  /// overrides such as `{\an8}`.
  static List<SubtitleCue> parseAss(String raw) {
    final lines = raw.replaceAll('\r', '').split('\n');
    final cues = <SubtitleCue>[];
    var inEvents = false;
    var fields = const <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        inEvents = trimmed.toLowerCase() == '[events]';
        continue;
      }
      if (!inEvents) continue;
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('format:')) {
        fields = trimmed
            .substring(7)
            .split(',')
            .map((field) => field.trim().toLowerCase())
            .toList(growable: false);
        continue;
      }
      if (!lower.startsWith('dialogue:')) continue;

      final body = trimmed.substring(9).trimLeft();
      final parts = body.split(',');
      final startIndex = fields.indexOf('start');
      final endIndex = fields.indexOf('end');
      final textIndex = fields.indexOf('text');
      // Standard ASS order when the Format line is missing or incomplete.
      final resolvedStart = startIndex >= 0 ? startIndex : 1;
      final resolvedEnd = endIndex >= 0 ? endIndex : 2;
      final resolvedText = textIndex >= 0 ? textIndex : 9;
      if (parts.length <= resolvedText) continue;

      final start = _parseAssTime(parts[resolvedStart]);
      final end = _parseAssTime(parts[resolvedEnd]);
      if (start == null || end == null || end <= start) continue;

      final text = parts
          .sublist(resolvedText)
          .join(',')
          .replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(RegExp(r'\\[Nn]'), '\n')
          .replaceAll(r'\h', ' ')
          .trim();
      if (text.isNotEmpty) {
        cues.add(SubtitleCue(start: start, end: end, text: text));
      }
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static Duration? _parseAssTime(String value) {
    final match = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?$')
        .firstMatch(value.trim());
    if (match == null) return null;
    final fraction = (match.group(4) ?? '0').padRight(3, '0').substring(0, 3);
    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
      milliseconds: int.parse(fraction),
    );
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
