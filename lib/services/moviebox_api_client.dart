import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/constants/api_constants.dart';
import '../core/provider/provider_failures.dart';

/// What the caller is asking the provider for. Used to map HTTP and payload
/// failures to meaningful typed errors.
enum ProviderRequestKind { search, stream, captions, auth }

/// An in-memory cached guest token with expiry awareness.
class GuestToken {
  final String token;
  final DateTime? expiresAt;

  const GuestToken({
    required this.token,
    this.expiresAt,
  });

  /// True if the token is expired or within 5 minutes of its expiration.
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(
      expiresAt!.subtract(const Duration(minutes: 5)),
    );
  }

  /// Parses token and expiry from the MovieBox `x-user` response header.
  ///
  /// Expected header shape:
  /// `{"token":"eyJ...","userId":"...","userType":0,"appType":3}`
  static GuestToken? fromXUserHeader(String? headerValue) {
    if (headerValue == null || headerValue.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(headerValue);
      if (decoded is Map) {
        final token = decoded['token']?.toString().trim() ?? '';
        if (token.isNotEmpty) {
          final expiry = parseJwtExpiry(token);
          return GuestToken(
            token: token,
            expiresAt: expiry ?? DateTime.now().add(const Duration(hours: 2)),
          );
        }
      }
    } catch (_) {
      // Malformed x-user JSON; ignore.
    }
    return null;
  }

  /// Parses token from a `Set-Cookie: token=...` header.
  static GuestToken? fromSetCookieHeader(String? setCookie) {
    if (setCookie == null || setCookie.isEmpty) return null;
    final match = RegExp(r'token=([^;]+)').firstMatch(setCookie);
    if (match != null) {
      final token = match.group(1)?.trim() ?? '';
      if (token.isNotEmpty) {
        final expiry = parseJwtExpiry(token);
        return GuestToken(
          token: token,
          expiresAt: expiry ?? DateTime.now().add(const Duration(hours: 2)),
        );
      }
    }
    return null;
  }

  /// Extracts the standard `exp` timestamp from a JWT payload.
  static DateTime? parseJwtExpiry(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;
      final normalized = base64Url.normalize(parts[1]);
      final payloadJson = utf8.decode(base64Url.decode(normalized));
      final payload = jsonDecode(payloadJson);
      if (payload is Map && payload['exp'] is num) {
        final expSec = (payload['exp'] as num).toInt();
        return DateTime.fromMillisecondsSinceEpoch(expSec * 1000);
      }
    } catch (_) {
      // Non-standard or unparseable JWT payload.
    }
    return null;
  }
}

/// Official MovieBox H5 API client with automatic guest token acquisition,
/// JWT rotation tracking, bounded retries, and typed provider failures.
class MovieBoxApiClient {
  final http.Client _client;
  final String baseUrl;
  final Duration defaultTimeout;
  final int maxAttempts;
  final Random _random;
  final Future<void> Function(Duration) _sleep;
  final bool _ownsClient;
  final String defaultHost;

  GuestToken? _cachedToken;
  Future<String?>? _harvestFlight;

  MovieBoxApiClient({
    http.Client? client,
    String? baseUrl,
    this.defaultTimeout = const Duration(seconds: 15),
    this.maxAttempts = 3,
    Random? random,
    Future<void> Function(Duration)? sleep,
    this.defaultHost = ApiConstants.movieboxHost,
    GuestToken? initialToken,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        baseUrl = baseUrl ?? ApiConstants.movieboxBaseUrl,
        _random = random ?? Random(),
        _sleep = sleep ?? Future<void>.delayed,
        _cachedToken = initialToken;

  /// The currently cached guest token, if any and unexpired.
  String? get currentToken =>
      (_cachedToken != null && !_cachedToken!.isExpired)
          ? _cachedToken!.token
          : null;

  /// Clears the cached guest token (used during auth recovery and tests).
  void clearTokenCache() {
    _cachedToken = null;
  }

  Uri buildUri(String path, [Map<String, String>? query]) {
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$cleanBase$cleanPath');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  /// Ensures a valid guest token is available, harvesting one if absent or expired.
  ///
  /// Concurrency-safe: concurrent calls share the same in-flight harvest request.
  Future<String?> ensureGuestToken({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedToken != null && !_cachedToken!.isExpired) {
      return _cachedToken!.token;
    }

    if (_harvestFlight != null) {
      return await _harvestFlight!;
    }

    final completer = Completer<String?>();
    _harvestFlight = completer.future;

    try {
      final token = await _harvestGuestToken();
      completer.complete(token);
      return token;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _harvestFlight = null;
    }
  }

  /// Calls the public MovieBox `/home?host=moviebox.ph` endpoint to harvest a guest token.
  ///
  /// The upstream BFF attaches an anonymous JWT in the `x-user` response header:
  /// `{"token":"eyJ...","userId":"...","userType":0,"appType":3}`.
  Future<String?> _harvestGuestToken() async {
    final uri = buildUri('/home', {'host': defaultHost});
    try {
      final response = await _client
          .get(uri, headers: ApiConstants.movieboxApiHeaders)
          .timeout(const Duration(seconds: 10));

      final token = _captureTokenFromHeaders(response.headers);
      if (token != null && token.isNotEmpty) {
        return token;
      }

      // Fallback: examine response body if token was embedded in JSON payload.
      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          final decoded = jsonDecode(_bodyText(response));
          if (decoded is Map) {
            final data = decoded['data'];
            final candidate = data is Map ? data['token'] : decoded['token'];
            if (candidate is String && candidate.isNotEmpty) {
              _cachedToken = GuestToken(
                token: candidate,
                expiresAt: GuestToken.parseJwtExpiry(candidate) ??
                    DateTime.now().add(const Duration(hours: 2)),
              );
              return candidate;
            }
          }
        } catch (_) {}
      }
    } catch (_) {
      // Harvest failure is non-fatal: calls will attempt to proceed or retry.
    }
    return _cachedToken?.token;
  }

  /// Inspects response headers for token rotation (`x-user` or `set-cookie`).
  String? _captureTokenFromHeaders(Map<String, String> headers) {
    // Look for x-user (case-insensitive)
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'x-user') {
        final parsed = GuestToken.fromXUserHeader(entry.value);
        if (parsed != null) {
          _cachedToken = parsed;
          return parsed.token;
        }
      }
    }

    // Look for Set-Cookie token=
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') {
        final parsed = GuestToken.fromSetCookieHeader(entry.value);
        if (parsed != null) {
          _cachedToken = parsed;
          return parsed.token;
        }
      }
    }

    return null;
  }

  /// Performs a bounded, retrying GET and returns the decoded JSON object.
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
    ProviderRequestKind kind = ProviderRequestKind.search,
    int? maxAttempts,
  }) =>
      requestJson(
        'GET',
        path,
        query: query,
        timeout: timeout,
        kind: kind,
        maxAttempts: maxAttempts,
      );

  /// Performs a bounded, retrying POST and returns the decoded JSON object.
  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration? timeout,
    ProviderRequestKind kind = ProviderRequestKind.search,
    int? maxAttempts,
  }) =>
      requestJson(
        'POST',
        path,
        body: body,
        query: query,
        timeout: timeout,
        kind: kind,
        maxAttempts: maxAttempts,
      );

  /// Unified request executor with guest token injection, token renewal,
  /// bounded retries, and typed provider error mapping.
  Future<Map<String, dynamic>> requestJson(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration? timeout,
    ProviderRequestKind kind = ProviderRequestKind.search,
    int? maxAttempts,
    bool skipAuth = false,
    bool retryOnAuthFail = true,
  }) async {
    final uri = buildUri(path, query);
    final limit = maxAttempts ?? this.maxAttempts;
    ProviderException? lastFailure;

    for (var attempt = 0; attempt < limit; attempt++) {
      try {
        final headers = Map<String, String>.from(ApiConstants.movieboxApiHeaders);

        if (!skipAuth) {
          final token = await ensureGuestToken();
          if (token != null && token.isNotEmpty) {
            headers['Authorization'] = 'Bearer $token';
          }
        }

        http.Response response;
        final timeoutDuration = timeout ?? defaultTimeout;

        if (method.toUpperCase() == 'POST') {
          headers['Content-Type'] = 'application/json';
          final encodedBody = body == null
              ? '{}'
              : (body is String ? body : jsonEncode(body));
          response = await _client
              .post(uri, headers: headers, body: encodedBody)
              .timeout(timeoutDuration);
        } else {
          response = await _client
              .get(uri, headers: headers)
              .timeout(timeoutDuration);
        }

        // Capture any rotated token upstream sent us
        _captureTokenFromHeaders(response.headers);

        final rawBody = _bodyText(response);

        // Check for token rejection (401 or 400 "invalid token")
        final isAuthFail = response.statusCode == 401 ||
            (response.statusCode == 400 && _isInvalidTokenMessage(rawBody));

        if (isAuthFail && retryOnAuthFail) {
          clearTokenCache();
          await ensureGuestToken(forceRefresh: true);
          // Retry the request immediately with fresh token
          return await requestJson(
            method,
            path,
            body: body,
            query: query,
            timeout: timeout,
            kind: kind,
            maxAttempts: 1,
            skipAuth: skipAuth,
            retryOnAuthFail: false,
          );
        }

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final decoded = _decode(rawBody, kind);
          _throwIfBusinessError(decoded, kind);
          return decoded;
        }

        final failure = _mapStatus(response.statusCode, rawBody, kind);
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

  bool _isInvalidTokenMessage(String body) {
    final lower = body.toLowerCase();
    return lower.contains('invalid token') ||
        lower.contains('token expired') ||
        lower.contains('token is invalid') ||
        lower.contains('auth fail');
  }

  Duration _backoff(int attempt) {
    final base = 300 * pow(3, attempt).toInt();
    final jitter = _random.nextInt(250);
    return Duration(milliseconds: (base + jitter).clamp(200, 4000).toInt());
  }

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

  /// Maps MovieBox business error codes (`code != 0`) inside HTTP 200 responses.
  void _throwIfBusinessError(
    Map<String, dynamic> decoded,
    ProviderRequestKind kind,
  ) {
    final code = decoded['code'];
    if (code is num && code != 0) {
      final msg = decoded['message']?.toString() ??
          decoded['msg']?.toString() ??
          decoded['reason']?.toString() ??
          '';
      final lowerMsg = msg.toLowerCase();

      if (code == 401 || lowerMsg.contains('token') || lowerMsg.contains('auth')) {
        throw ProviderException(
          ProviderErrorType.playbackForbidden,
          'The provider refused this request.',
          diagnostic: 'code $code: $msg',
          statusCode: 401,
        );
      }
      if (code == 404 || lowerMsg.contains('not found')) {
        if (kind == ProviderRequestKind.search) {
          throw ProviderException(
            ProviderErrorType.noProviderMatch,
            'The provider has no record of this title.',
            diagnostic: 'code $code: $msg',
            statusCode: 404,
          );
        }
        throw ProviderException(
          ProviderErrorType.streamExpired,
          'This stream link is no longer available.',
          diagnostic: 'code $code: $msg',
          statusCode: 404,
        );
      }
      if (code == 429 || lowerMsg.contains('limit') || lowerMsg.contains('frequent')) {
        throw ProviderException(
          ProviderErrorType.providerRateLimited,
          'The streaming service asked Flix to slow down.',
          diagnostic: 'code $code: $msg',
          statusCode: 429,
        );
      }
      if (code >= 500) {
        throw ProviderException(
          ProviderErrorType.providerUnavailable,
          'The streaming service is having trouble right now.',
          diagnostic: 'code $code: $msg',
          statusCode: code.toInt(),
        );
      }
      throw ProviderException(
        ProviderErrorType.invalidProviderResponse,
        'The streaming service rejected this request.',
        diagnostic: 'code $code: $msg',
      );
    }
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

  String? _upstreamErrorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final code = decoded['error'] ?? decoded['code'] ?? decoded['reason'];
        if (code != null) {
          final text = code.toString().trim();
          return text.isEmpty
              ? null
              : text.substring(0, text.length.clamp(0, 48));
        }
      }
    } catch (_) {}
    return null;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// Backwards-compatibility alias for ZarhostingApiClient.
typedef ZarhostingApiClient = MovieBoxApiClient;
