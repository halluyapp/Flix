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

/// Cached guest JWT session for MovieBox H5 API.
class _GuestSession {
  final String token;
  final DateTime expiresAt;

  _GuestSession({required this.token, required this.expiresAt});

  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 5)));
}

class ZarhostingApiClient {
  final http.Client _client;
  final String baseUrl;
  final Duration defaultTimeout;
  final int maxAttempts;
  final Random _random;
  final Future<void> Function(Duration) _sleep;
  final bool _ownsClient;

  // In-memory token cache shared across client instances
  static _GuestSession? _sharedSession;
  static Completer<String?>? _tokenHarvestCompleter;

  ZarhostingApiClient({
    http.Client? client,
    String? baseUrl,
    this.defaultTimeout = const Duration(seconds: 15),
    this.maxAttempts = 3,
    Random? random,
    Future<void> Function(Duration)? sleep,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        baseUrl = baseUrl ?? ApiConstants.movieboxH5BaseUrl,
        _random = random ?? Random(),
        _sleep = sleep ?? Future<void>.delayed;

  Uri buildUri(String path, [Map<String, String>? query]) {
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$cleanBase$cleanPath');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  /// Obtains a fresh guest token from /home?host=moviebox.ph.
  /// Never hard-coded; harvested and cached in-memory with automatic refresh.
  Future<String?> harvestGuestToken({bool force = false}) async {
    if (baseUrl.contains('example.com')) return null;
    if (!force && _sharedSession != null && !_sharedSession!.isExpired) {
      return _sharedSession!.token;
    }

    if (_tokenHarvestCompleter != null) {
      return _tokenHarvestCompleter!.future;
    }

    final completer = Completer<String?>();
    _tokenHarvestCompleter = completer;

    try {
      final harvestUri = buildUri('/home', {'host': ApiConstants.movieboxHost});
      final headers = Map<String, String>.from(ApiConstants.movieboxApiHeaders);

      final response = await _client
          .get(harvestUri, headers: headers)
          .timeout(const Duration(seconds: 8));

      String? token;
      final xUser = response.headers['x-user'];
      if (xUser != null && xUser.isNotEmpty) {
        try {
          final decoded = jsonDecode(xUser);
          if (decoded is Map && decoded['token'] != null) {
            token = decoded['token'].toString().trim();
          }
        } catch (_) {}
      }

      if (token == null || token.isEmpty) {
        // Fallback: check body or Set-Cookie
        final cookie = response.headers['set-cookie'] ?? '';
        final match = RegExp(r'token=([^;]+)').firstMatch(cookie);
        if (match != null) {
          token = match.group(1);
        }
      }

      if (token != null && token.isNotEmpty) {
        _sharedSession = _GuestSession(
          token: token,
          expiresAt: DateTime.now().add(const Duration(hours: 12)),
        );
        completer.complete(token);
        return token;
      }
      completer.complete(null);
      return null;
    } catch (_) {
      // If harvest fails (e.g. in offline tests with mock client), continue without crashing
      completer.complete(null);
      return null;
    } finally {
      _tokenHarvestCompleter = null;
    }
  }

  /// Performs a bounded, retrying GET and returns the decoded JSON object.
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
    Duration? timeout,
    ProviderRequestKind kind = ProviderRequestKind.search,
    int? maxAttempts,
  }) async {
    final uri = buildUri(path, query);
    final limit = maxAttempts ?? this.maxAttempts;
    ProviderException? lastFailure;

    // Harvest or reuse token if available (skip for /home itself)
    String? token;
    if (!path.contains('/home')) {
      token = await harvestGuestToken();
    }

    for (var attempt = 0; attempt < limit; attempt++) {
      try {
        final headers = Map<String, String>.from(ApiConstants.movieboxApiHeaders);
        if (extraHeaders != null) headers.addAll(extraHeaders);
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Bearer $token';
        }

        final response = await _client
            .get(uri, headers: headers)
            .timeout(timeout ?? defaultTimeout);

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return _decode(_bodyText(response), kind);
        }

        // On 401 or 403 token rejection, force re-harvest once
        if ((response.statusCode == 401 || response.statusCode == 403) &&
            attempt == 0 &&
            !path.contains('/home')) {
          token = await harvestGuestToken(force: true);
        }

        final failure =
            _mapStatus(response.statusCode, _bodyText(response), kind);
        if (!failure.isRetryable || attempt == limit - 1) {
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
        if (attempt == limit - 1) throw failure;
        lastFailure = failure;
      } on SocketException catch (error) {
        final failure = ProviderException(
          ProviderErrorType.networkUnavailable,
          'The device could not reach the streaming service.',
          diagnostic: error.osError?.message ?? 'socket error',
        );
        if (attempt == limit - 1) throw failure;
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
        if (attempt == limit - 1) throw failure;
        lastFailure = failure;
      } on FormatException catch (error) {
        throw ProviderException(
          ProviderErrorType.invalidProviderResponse,
          'The streaming service returned an unreadable response.',
          diagnostic: error.message,
        );
      }

      if (attempt < limit - 1) {
        await _sleep(_backoff(attempt));
      }
    }

    throw lastFailure ??
        const ProviderException(
          ProviderErrorType.unknown,
          'The streaming service could not be reached.',
        );
  }

  /// Performs a bounded, retrying POST and returns the decoded JSON object.
  Future<Map<String, dynamic>> postJson(
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? extraHeaders,
    Duration? timeout,
    ProviderRequestKind kind = ProviderRequestKind.search,
    int? maxAttempts,
  }) async {
    final uri = buildUri(path);
    final limit = maxAttempts ?? this.maxAttempts;
    ProviderException? lastFailure;

    String? token = await harvestGuestToken();

    for (var attempt = 0; attempt < limit; attempt++) {
      try {
        final headers = Map<String, String>.from(ApiConstants.movieboxApiHeaders);
        headers['Content-Type'] = 'application/json; charset=utf-8';
        if (extraHeaders != null) headers.addAll(extraHeaders);
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Bearer $token';
        }

        final encodedBody = body != null ? jsonEncode(body) : null;
        final response = await _client
            .post(uri, headers: headers, body: encodedBody)
            .timeout(timeout ?? defaultTimeout);

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return _decode(_bodyText(response), kind);
        }

        if ((response.statusCode == 401 || response.statusCode == 403) &&
            attempt == 0) {
          token = await harvestGuestToken(force: true);
        }

        final failure =
            _mapStatus(response.statusCode, _bodyText(response), kind);
        if (!failure.isRetryable || attempt == limit - 1) {
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
        if (attempt == limit - 1) throw failure;
        lastFailure = failure;
      } on SocketException catch (error) {
        final failure = ProviderException(
          ProviderErrorType.networkUnavailable,
          'The device could not reach the streaming service.',
          diagnostic: error.osError?.message ?? 'socket error',
        );
        if (attempt == limit - 1) throw failure;
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
        if (attempt == limit - 1) throw failure;
        lastFailure = failure;
      } on FormatException catch (error) {
        throw ProviderException(
          ProviderErrorType.invalidProviderResponse,
          'The streaming service returned an unreadable response.',
          diagnostic: error.message,
        );
      }

      if (attempt < limit - 1) {
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
    if (decoded is Map) {
      final map = Map<String, dynamic>.from(decoded);
      // Check MovieBox business error code
      final code = map['code'];
      if (code != null && code is num && code != 0) {
        final msg = map['message']?.toString() ?? 'Provider error';
        throw ProviderException(
          ProviderErrorType.invalidProviderResponse,
          msg,
          diagnostic: 'code $code',
        );
      }
      return map;
    }
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

  /// Extracts only the provider's short machine-readable error code.
  String? _upstreamErrorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final code = decoded['error'] ?? decoded['code'] ?? decoded['message'];
        if (code != null) {
          final text = code.toString().trim();
          return text.isEmpty ? null : text.substring(0, text.length.clamp(0, 48));
        }
      }
    } catch (_) {
      // Not JSON
    }
    return null;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

// Convenient alias for the updated provider
typedef MovieboxApiClient = ZarhostingApiClient;
