import 'dart:io';

/// Coarse hardware profile used to keep Flix stable on low-memory phones.
///
/// Nothing is removed on a small device: images are decoded at the size they
/// are drawn, the bitmap cache is capped, and playback prefers an SD/HD file
/// instead of a 1080p one that would exhaust a 32-bit heap.
class DeviceProfile {
  DeviceProfile._({
    required this.totalMemoryMb,
    required this.physicalCores,
  });

  static DeviceProfile? _instance;

  static DeviceProfile get instance => _instance ??= _detect();

  /// Total physical RAM reported by the OS, or 0 when unknown.
  final int totalMemoryMb;
  final int physicalCores;

  /// Phones in the 2 GB class (Android reports slightly less than the box
  /// says). These are usually 32-bit processes with a 128-192 MB heap.
  bool get lowMemory => totalMemoryMb > 0 && totalMemoryMb <= 2600;

  bool get veryLowMemory => totalMemoryMb > 0 && totalMemoryMb <= 1600;

  /// Poster/backdrop decode widths. A w500 poster is already ~1.5 MB once
  /// decoded; decoding it at card size keeps a full grid affordable.
  int get posterDecodeWidth => lowMemory ? 300 : 500;
  int get backdropDecodeWidth => veryLowMemory ? 640 : 900;

  int get imageCacheBytes =>
      lowMemory ? 24 * 1024 * 1024 : 96 * 1024 * 1024;
  int get imageCacheEntries => lowMemory ? 60 : 180;

  /// Highest video quality worth decoding here; 0 means "best available".
  int get preferredMaxQuality {
    if (veryLowMemory) return 480;
    if (lowMemory) return 720;
    return 0;
  }

  static DeviceProfile _detect() {
    var totalMb = 0;
    try {
      final meminfo = File('/proc/meminfo');
      if (meminfo.existsSync()) {
        for (final line in meminfo.readAsLinesSync()) {
          if (!line.startsWith('MemTotal:')) continue;
          final match = RegExp(r'\d+').firstMatch(line);
          final kb = int.tryParse(match?.group(0) ?? '');
          if (kb != null && kb > 0) totalMb = kb ~/ 1024;
          break;
        }
      }
    } catch (_) {
      // Desktop/iOS do not expose /proc/meminfo; fall back to "not low".
    }

    var cores = 1;
    try {
      cores = Platform.numberOfProcessors;
    } catch (_) {
      cores = 1;
    }

    return DeviceProfile._(totalMemoryMb: totalMb, physicalCores: cores);
  }
}
