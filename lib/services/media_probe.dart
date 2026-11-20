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
/// with HTTP 429. Checking before playback/download lets Flix skip a dead link
/// or say honestly that the provider refused it, instead of spinning.
class MediaProbe {
  MediaProbe({
    http.Client? client,
    this.timeout = const Duration(seconds: 3),
    this.retryDelay = const Duration(milliseconds: 1200),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final Duration retryDelay;

  Future<MediaProbeResult> check(
    StreamSource source, {
    List<Map<String, String>>? profiles,
  }) async {
    final attempts = profiles ??
        ApiConstants.zarhostingMediaHeaderProfiles
            .map((profile) => <String, String>{...profile, ...source.headers})
            .toList(growable: false);

    var lastStatus = 0;
    var transportFailure = false;

    for (final headers in attempts) {
      for (var pass = 0; pass < 2; pass++) {
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
          if (status == 429 && pass == 0) {
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
    }

    final onlyTransport = transportFailure && lastStatus == 0;
    return MediaProbeResult(
      reachable: onlyTransport,
      inconclusive: onlyTransport,
      statusCode: lastStatus,
    );
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
