/// Typed failures for the direct Zarhosting provider integration.
///
/// The provider is an external service: every failure needs to be
/// distinguishable so the UI can offer an honest recovery action instead of a
/// generic "something went wrong" state.
enum ProviderErrorType {
  noProviderMatch,
  ambiguousProviderMatch,
  providerTimeout,
  providerRateLimited,
  providerUnavailable,
  invalidProviderResponse,
  missingProviderIdentifier,
  noPlayableSources,
  unsupportedStreamFormat,
  streamExpired,
  playbackForbidden,
  networkUnavailable,
  unknown,
}

extension ProviderErrorTypeX on ProviderErrorType {
  String get technicalCode => name;

  /// True only for failures where a later retry can plausibly succeed without
  /// any user action.
  bool get isRetryable => switch (this) {
        ProviderErrorType.providerTimeout ||
        ProviderErrorType.providerRateLimited ||
        ProviderErrorType.providerUnavailable ||
        ProviderErrorType.networkUnavailable ||
        ProviderErrorType.streamExpired =>
          true,
        _ => false,
      };

  /// Failures that indicate the resolved playback URL itself is no longer
  /// usable and the provider has to be asked again.
  bool get invalidatesStream => switch (this) {
        ProviderErrorType.streamExpired ||
        ProviderErrorType.playbackForbidden ||
        ProviderErrorType.noPlayableSources =>
          true,
        _ => false,
      };
}

class ProviderException implements Exception {
  final ProviderErrorType type;

  /// Short, user-facing message. Never contains credentials, signed URLs or
  /// provider internals.
  final String message;

  /// Optional internal context for diagnostics. Sanitized before logging.
  final String? diagnostic;

  final int? statusCode;

  const ProviderException(
    this.type,
    this.message, {
    this.diagnostic,
    this.statusCode,
  });

  bool get isRetryable => type.isRetryable;
  bool get invalidatesStream => type.invalidatesStream;

  ProviderException withDiagnostic(String value) => ProviderException(
        type,
        message,
        diagnostic: value,
        statusCode: statusCode,
      );

  @override
  String toString() => message;
}
