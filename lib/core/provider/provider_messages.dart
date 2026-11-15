import 'provider_failures.dart';

/// Converts typed provider failures into honest, actionable copy.
///
/// Keeping this in one place stops individual screens from inventing messages
/// and guarantees that a technical failure never leaks a signed URL or a raw
/// provider error body to the viewer.
class ProviderMessages {
  const ProviderMessages._();

  static String titleFor(ProviderErrorType type) => switch (type) {
        ProviderErrorType.noProviderMatch => 'Title not available yet',
        ProviderErrorType.ambiguousProviderMatch => 'Which version did you mean?',
        ProviderErrorType.providerTimeout => 'The streaming service is slow',
        ProviderErrorType.providerRateLimited => 'Too many requests',
        ProviderErrorType.providerUnavailable => 'Streaming service unavailable',
        ProviderErrorType.invalidProviderResponse => 'Unreadable stream response',
        ProviderErrorType.missingProviderIdentifier =>
          'Missing provider identifier',
        ProviderErrorType.noPlayableSources => 'Full stream unavailable',
        ProviderErrorType.unsupportedStreamFormat => 'Unsupported format',
        ProviderErrorType.streamExpired => 'Stream link expired',
        ProviderErrorType.playbackForbidden => 'Playback not allowed',
        ProviderErrorType.networkUnavailable => 'No internet connection',
        ProviderErrorType.unknown => 'Playback could not start',
      };

  static String bodyFor(ProviderErrorType type) => switch (type) {
        ProviderErrorType.noProviderMatch =>
          'Flix could not find this exact title on the streaming provider. '
              'You can pick another title or try again later.',
        ProviderErrorType.ambiguousProviderMatch =>
          'Several provider titles match this one. Choose the correct version '
              'so Flix does not play the wrong title.',
        ProviderErrorType.providerTimeout =>
          'The provider did not answer in time. Your connection is working, so '
              'try again in a moment.',
        ProviderErrorType.providerRateLimited =>
          'The provider asked Flix to slow down. Wait a few seconds, then retry.',
        ProviderErrorType.providerUnavailable =>
          'The streaming provider is having trouble right now. Retry shortly.',
        ProviderErrorType.invalidProviderResponse =>
          'The provider returned a response Flix could not read. Retrying is '
              'safe; if it keeps happening the provider changed its API.',
        ProviderErrorType.missingProviderIdentifier =>
          'This provider record is missing the identifier needed to play it. '
              'Pick a different match or try another title.',
        ProviderErrorType.noPlayableSources =>
          'The provider has no full-length stream for this title right now.',
        ProviderErrorType.unsupportedStreamFormat =>
          'This source uses a format the built-in player cannot open.',
        ProviderErrorType.streamExpired =>
          'The signed stream link expired. Flix can fetch a fresh one.',
        ProviderErrorType.playbackForbidden =>
          'The provider refused playback for this source. Choose another '
              'version or try again later.',
        ProviderErrorType.networkUnavailable =>
          'Connect to the internet to stream. Anything already downloaded '
              'still plays offline.',
        ProviderErrorType.unknown =>
          'Something interrupted playback. Retry, or choose another source.',
      };

  static String actionLabel(ProviderErrorType type) => switch (type) {
        ProviderErrorType.noProviderMatch => 'Back to details',
        ProviderErrorType.ambiguousProviderMatch => 'Choose a version',
        ProviderErrorType.networkUnavailable => 'Retry when online',
        ProviderErrorType.streamExpired => 'Refresh stream',
        ProviderErrorType.noPlayableSources => 'Try again',
        ProviderErrorType.unsupportedStreamFormat => 'Choose another source',
        _ => 'Retry',
      };
}
