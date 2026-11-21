import 'dart:async';

import 'package:http/http.dart' as http;

import '../core/constants/api_constants.dart';
import '../models/stream_source.dart';

/// Outcome of a lightweight check that a media URL is really fetchable with
/// the headers Flix is about to use.
class MediaProbeResult {
  const MediaProbeResult({
    required this.reachable,
    required this.inconclusive,
    required this.statusCode,
  });

  /// The CDN answered with bytes (200/206) or told us the range is unusable
  /// but the resource exists (416).
  final bool reachable;

  /// The check itself could not run (offline, DNS, timeout). Callers should
  /// continue as if the URL were fine rather than blocking the user because of
  /// Flix's own probe.
  final bool inconclusive;

  final int statusCode;

  bool get blocked => !reachable && !inconclusive;

  bool get rateLimited => statusCode == 429;

  String get description {
    if (reachable) return 'reachable';
    if (inconclusive) return 'unknown';
    return 'HTTP $statusCode';
  }
}

/// Asks the media CDN for the first two bytes of a stream.
///
/// Provider links are signed and short-lived, and the CDN rate-limits bursts
/// with HTTP 429. The probe is deliberately bounded — the verified primary
/// header profile (with one HTTP 429 retry), at most [maxFallbacks] fallback
/// profiles, one attempt per profile, and a hard total budget — so a download
/// is never held up by Flix's own probing. Anything that cannot be answered
/// inside the budget is reported as inconclusive, which callers treat as
/// "proceed": Flix never blocks a download because of its own probe, only
/// because of the provider.
class MediaProbe {
  MediaProbe({
    http.Client? client,
    this.timeout = const Duration(seconds: 3),
    this.retryDelay = const Duration(milliseconds: 1200),
    this.budget = const Duration(seconds: 8),
    this.maxFallbacks = 2,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final Duration retryDelay;
  final Duration budget;
  final int maxFallbacks;

  /// The verified primary header profile followed by at most [maxFallbacks]
  /// verified fallbacks. Source-specific headers ride on top of each.
  List<Map<String, String>> _profiles(StreamSource source) {
    final all = ApiConstants.zarhostingMediaHeaderProfiles
        .map((profile) => <String, String>{...profile, ...source.headers})
        .toList(growable: false);
    if (all.isEmpty) return const [];
    final limit = (1 + maxFallbacks).clamp(1, all.length);
    return all.sublist(0, limit);
  }

  Future<MediaProbeResult> check(
    StreamSource source, {
    List<Map<String, String>>? profiles,
    Duration? budget,
  }) async {
    try {
      return await _checkTimed(
        source,
        profiles ?? _profiles(source),
      ).timeout(
        budget ?? this.budget,
        onTimeout: () => MediaProbeResult(
          reachable: true,
          inconclusive: true,
          statusCode: 0,
        ),
      );
    } catch (_) {
      // A probe that cannot run never blocks a download.
      return MediaProbeResult(
        reachable: true,
        inconclusive: true,
        statusCode: 0,
      );
    }
  }

  Future<MediaProbeResult> _checkTimed(
    StreamSource source,
    List<Map<String, String>> profiles,
  ) async {
    if (profiles.isEmpty) {
      return MediaProbeResult(
        reachable: true,
        inconclusive: true,
        statusCode: 0,
      );
    }

    var lastStatus = 0;

    for (var index = 0; index < profiles.length; index++) {
      final headers = profiles[index];
      final isPrimary = index == 0;
      var transportFailure = false;
      // The primary profile gets one HTTP 429 re-check after the delay;
      // fallback profiles make a single attempt.
      for (var pass = 0; pass < (isPrimary ? 2 : 1); pass++) {
        try {
          final request = http.Request('GET', Uri.parse(source.url))
            ..headers.addAll(headers)
            ..headers['Range'] = 'bytes=0-1';
          final response = await _client.send(request).timeout(timeout);
          final status = response.statusCode;
          // Never download more than the requested range.
          await response.stream.listen(null).cancel();
          lastStatus = status;
          if (status == 200 || status == 206 || status == 416) {
            return MediaProbeResult(
              reachable: true,
              inconclusive: false,
              statusCode: status,
            );
          }
          if (status == 429 && isPrimary && pass == 0) {
            await Future<void>.delayed(retryDelay);
            continue;
          }
          break;
        } on TimeoutException {
          transportFailure = true;
          break;
        } catch (_) {
          transportFailure = true;
          break;
        }
      }

      if (transportFailure) {
        // A transport-level answer cannot reach any header profile, so the
        // check is inconclusive rather than blocked.
        return MediaProbeResult(
          reachable: true,
          inconclusive: true,
          statusCode: lastStatus,
        );
      }

      // A header-shaped rejection on the primary profile may be a rotated
      // header requirement; try the next profile. Any other decisive answer
      // (404, 410, 5xx, …) stops the check immediately.
      if (lastStatus != 0 && isPrimary && _isHeaderRejection(lastStatus)) {
        continue;
      }
      break;
    }

    if (lastStatus == 0) {
      return MediaProbeResult(
        reachable: true,
        inconclusive: true,
        statusCode: 0,
      );
    }
    return MediaProbeResult(
      reachable: false,
      inconclusive: false,
      statusCode: lastStatus,
    );
  }

  /// Auth/origin-style rejections: only these can be fixed by a different
  /// header profile. A dead or moved file cannot be, so those stop the check.
  static bool _isHeaderRejection(int status) {
    return status == 401 ||
        status == 403 ||
        status == 426 ||
        status == 428 ||
        status == 429;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
