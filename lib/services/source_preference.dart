import '../models/stream_source.dart';
import 'device_profile.dart';

/// Picks the source Flix starts with: the best available file normally, and a
/// sustainable SD/HD file on a low-memory phone so ExoPlayer cannot exhaust a
/// 32-bit heap. Every other quality stays selectable in the player and in the
/// download sheet.
StreamSource? preferredSource(List<StreamSource> sources, {int? maxQuality}) {
  if (sources.isEmpty) return null;
  final cap = maxQuality ?? DeviceProfile.instance.preferredMaxQuality;
  if (cap <= 0) return sources.first;
  for (final source in sources) {
    if (source.qualityValue > 0 && source.qualityValue <= cap) {
      return source;
    }
  }
  // Sources are ordered best-first, so the last one is the smallest known.
  return sources.last;
}

/// Every source worth trying, in the order Flix should try them.
///
/// The preferred source comes first. Every other source follows from the
/// smallest upwards, so a phone that cannot decode a 4K file recovers on a
/// smaller one instead of giving up after the next-largest quality.
List<StreamSource> playbackCandidates(
  List<StreamSource> sources, {
  int? maxQuality,
}) {
  if (sources.isEmpty) return const [];
  final first = preferredSource(sources, maxQuality: maxQuality)!;
  final rest = sources.where((source) => source.url != first.url).toList()
    ..sort((a, b) => _rank(a).compareTo(_rank(b)));
  return <StreamSource>[first, ...rest].take(6).toList(growable: false);
}

/// Lower is tried earlier. Quality dominates; at the same quality a plain MP4
/// (H.264) is preferred over DASH (often HEVC), which low-end decoders lack.
int _rank(StreamSource source) {
  final quality = source.qualityValue <= 0 ? 100000 : source.qualityValue;
  final codecPenalty = source.formatKind == StreamFormat.dash ? 1 : 0;
  return quality * 2 + codecPenalty;
}
