import '../models/stream_source.dart';
import 'device_profile.dart';

/// Picks the source Flix starts with: the best available file normally, and a
/// sustainable SD/HD file on a low-memory phone so ExoPlayer cannot exhaust a
/// 32-bit heap. Every other quality stays selectable in the player and in the
/// download sheet.
StreamSource? preferredSource(List<StreamSource> sources) {
  if (sources.isEmpty) return null;
  final maxQuality = DeviceProfile.instance.preferredMaxQuality;
  if (maxQuality <= 0) return sources.first;
  for (final source in sources) {
    if (source.qualityValue > 0 && source.qualityValue <= maxQuality) {
      return source;
    }
  }
  // Sources are ordered best-first, so the last one is the smallest known.
  return sources.last;
}
