import '../core/provider/provider_failures.dart';
import 'caption_track.dart';

/// Outcome of one caption discovery for one exact movie or episode.
///
/// The status keeps four situations apart that the UI must never merge:
/// a genuinely empty list, an unreadable provider payload, a provider or
/// network failure, and a lookup that is still running.
enum CaptionLoadStatus {
  /// The provider returned at least one usable subtitle track.
  loaded,

  /// The provider answered correctly and listed no subtitles.
  empty,

  /// The provider answered, but no record in the response could be read.
  unsupported,

  /// The request itself failed (transport, timeout, HTTP error).
  failed,

  /// Discovery is still running; the video can play meanwhile.
  pending,
}

class CaptionLoad {
  final CaptionLoadStatus status;
  final List<CaptionTrack> tracks;
  final ProviderException? failure;

  /// Structure label of the response (for example `list:captions`), used in
  /// diagnostics only.
  final String shape;
  final int rawCount;
  final int rejectedCount;

  /// Distinct machine-readable reasons for rejected records.
  final List<String> rejectionReasons;

  CaptionLoad({
    required this.status,
    this.tracks = const [],
    this.failure,
    this.shape = 'none',
    this.rawCount = 0,
    this.rejectedCount = 0,
    this.rejectionReasons = const [],
  });

  /// Wraps an already-known track list (used for cached or legacy streams).
  factory CaptionLoad.ofTracks(List<CaptionTrack> tracks) => CaptionLoad(
        status: tracks.isEmpty ? CaptionLoadStatus.empty : CaptionLoadStatus.loaded,
        tracks: List.unmodifiable(tracks),
        shape: 'known',
        rawCount: tracks.length,
      );

  factory CaptionLoad.failed(ProviderException failure) => CaptionLoad(
        status: CaptionLoadStatus.failed,
        failure: failure,
        shape: 'request_failed',
      );

  factory CaptionLoad.pending() => CaptionLoad(
        status: CaptionLoadStatus.pending,
        shape: 'pending',
      );

  bool get isLoaded => status == CaptionLoadStatus.loaded;
  bool get isPending => status == CaptionLoadStatus.pending;

  /// Short, user-safe explanation. Never claims "no subtitles" unless the
  /// provider actually said so.
  String get userMessage => switch (status) {
        CaptionLoadStatus.loaded => '',
        CaptionLoadStatus.empty => 'No subtitles found for this episode.',
        CaptionLoadStatus.unsupported =>
          'The provider sent subtitle data Flix could not read.',
        CaptionLoadStatus.failed => failure?.message.isNotEmpty == true
            ? '${failure!.message} Video playback is not affected.'
            : 'Subtitles could not be loaded. Video playback is not affected.',
        CaptionLoadStatus.pending => 'Loading subtitles…',
      };
}
