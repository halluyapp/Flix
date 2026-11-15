import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/constants/api_constants.dart';
import '../core/provider/provider_failures.dart';

/// What the caller is asking the provider for. Used to map HTTP failures to
/// meaningful typed errors (a 404 on search is "nothing matched", a 404 on a
/// stream is a stale/unavailable source).
enum ProviderRequestKind { search, stream, captions }

class ZarhostingApiClient {
  final http.Client _client;
  final String baseUrl;
  final Duration defaultTimeout;
  final int maxAttempts;
  final Random _random;
  final Future<void> Function(Duration) _sleep;
  final bool _ownsClient;

  ZarhostingApiClient({
    http.Client? client,
    String? baseUrl,
    this.defaultTimeout = const Duration(seconds: 15),
    this.maxAttempts = 3,
    Random? random,
    Future<void> Function(Duration)? sleep,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        baseUrl = baseUrl ?? ApiConstants.zarhostingBaseUrl,
        _random = random ?? Random(),
        _sleep = sleep ?? Future<void>.delayed;

  Uri buildUri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  /// Performs a bounded, retrying GET and returns the decoded JSON object.
  ///
  /// Only transient failures are retried. Permanent client errors fail
  /// immediately so the UI can show an accurate reason.
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
    ProviderRequestKind kind = ProviderRequestKind.search,
  }) async {
    final uri = buildUri(path, query);
    ProviderException? lastFailure;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final response = await _client
            .get(uri, headers: ApiConstants.zarhostingApiHeaders)
            .timeout(timeout ?? defaultTimeout);

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return _decode(_bodyText(response), kind);
        }

        final failure =
            _mapStatus(response.statusCode, _bodyText(response), kind);
        if (!failure.isRetryable || attempt == maxAttempts - 1) {
          throw failure;
        }
        lastFailure = failure;
      } on ProviderException {
        rethrow;
      } on TimeoutException {
        final failure = ProviderException(
          ProviderErrorType.providerTimeout,
          'The streaming service did not respond in time.',
          diagnostic: 'timeout after ${(timeout ?? defaultTimeout).inSeconds}s',
        );
        if (attempt == maxAttempts - 1) throw failure;
        lastFailure = failure;
      } on SocketException catch (error) {
        final failure = ProviderException(
          ProviderErrorType.networkUnavailable,
          'The device could not reach the streaming service.',
          diagnostic: error.osError?.message ?? 'socket error',
        );
        if (attempt == maxAttempts - 1) throw failure;
        lastFailure = failure;
      } on HandshakeException {
        throw const ProviderException(
          ProviderErrorType.providerUnavailable,
          'The streaming service presented an invalid security certificate.',
          diagnostic: 'tls handshake failed',
        );
      } on http.ClientException catch (error) {
        final failure = ProviderException(
          ProviderErrorType.networkUnavailable,
          'The connection to the streaming service was interrupted.',
          diagnostic: error.message,
        );
        if (attempt == maxAttempts - 1) throw failure;
        lastFailure = failure;
      } on FormatException catch (error) {
        throw ProviderException(
          ProviderErrorType.invalidProviderResponse,
          'The streaming service returned an unreadable response.',
          diagnostic: error.message,
        );
      }

      if (attempt < maxAttempts - 1) {
        await _sleep(_backoff(attempt));
      }
    }

    throw lastFailure ??
        const ProviderException(
          ProviderErrorType.unknown,
          'The streaming service could not be reached.',
        );
  }

  Duration _backoff(int attempt) {
    final base = 300 * pow(3, attempt).toInt();
    final jitter = _random.nextInt(250);
    return Duration(milliseconds: (base + jitter).clamp(200, 4000).toInt());
  }

  /// Decodes a provider body as UTF-8 no matter what charset the response
  /// declares, so Arabic/Latin-accented titles and caption names stay intact.
  static String _bodyText(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } on FormatException {
      return response.body;
    }
  }

  Map<String, dynamic> _decode(String body, ProviderRequestKind kind) {
    if (body.trim().isEmpty) {
      throw const ProviderException(
        ProviderErrorType.invalidProviderResponse,
        'The streaming service returned an empty response.',
        diagnostic: 'empty body',
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const ProviderException(
        ProviderErrorType.invalidProviderResponse,
        'The streaming service returned an unreadable response.',
        diagnostic: 'invalid json',
      );
    }
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    if (decoded is List) return {'items': decoded};
    throw ProviderException(
      ProviderErrorType.invalidProviderResponse,
      'The streaming service returned an unexpected response shape.',
      diagnostic: 'json root ${decoded.runtimeType}',
    );
  }

  ProviderException _mapStatus(
    int status,
    String body,
    ProviderRequestKind kind,
  ) {
    final upstreamCode = _upstreamErrorCode(body);
    final diagnostic =
        upstreamCode == null ? 'http $status' : 'http $status ($upstreamCode)';

    if (status == 401 || status == 403) {
      return ProviderException(
        ProviderErrorType.playbackForbidden,
        'The provider refused this request.',
        diagnostic: diagnostic,
        statusCode: status,
      );
    }
    if (status == 404 || status == 410) {
      if (kind == ProviderRequestKind.search) {
        return ProviderException(
          ProviderErrorType.noProviderMatch,
          'The provider has no record of this title.',
          diagnostic: diagnostic,
          statusCode: status,
        );
      }
      return ProviderException(
        ProviderErrorType.streamExpired,
        'This stream link is no longer available.',
        diagnostic: diagnostic,
        statusCode: status,
      );
    }
    if (status == 408) {
      return ProviderException(
        ProviderErrorType.providerTimeout,
        'The streaming service did not respond in time.',
        diagnostic: diagnostic,
        statusCode: status,
      );
    }
    if (status == 429) {
      return ProviderException(
        ProviderErrorType.providerRateLimited,
        'The streaming service asked Flix to slow down.',
        diagnostic: diagnostic,
        statusCode: status,
      );
    }
    if (status >= 500) {
      return ProviderException(
        ProviderErrorType.providerUnavailable,
        'The streaming service is having trouble right now.',
        diagnostic: diagnostic,
        statusCode: status,
      );
    }
    return ProviderException(
      ProviderErrorType.invalidProviderResponse,
      'The streaming service rejected this request.',
      diagnostic: diagnostic,
      statusCode: status,
    );
  }

  /// Extracts only the provider's short machine-readable error code. The full
  /// upstream message is never surfaced: it can contain internal host details.
  String? _upstreamErrorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final code = decoded['error'] ?? decoded['code'];
        if (code != null) {
          final text = code.toString().trim();
          return text.isEmpty ? null : text.substring(0, text.length.clamp(0, 48));
        }
      }
    } catch (_) {
      // Not JSON; no machine-readable code.
    }
    return null;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
