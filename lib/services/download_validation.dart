import 'dart:io';

/// Pure helpers for safe offline file management and integrity checks.
class DownloadValidation {
  const DownloadValidation._();

  static String safeName(String value, {int maxLength = 48}) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (cleaned.isEmpty) return 'title';
    return cleaned.substring(0, cleaned.length.clamp(0, maxLength).toInt());
  }

  /// Deterministic, collision-safe video file name. The timestamp suffix keeps
  /// a re-download from ever overwriting a working offline copy.
  static String videoFileName({
    required String title,
    required int tmdbId,
    required bool isEpisode,
    required int season,
    required int episode,
    required int qualityValue,
    required int stamp,
  }) {
    final episodePart = isEpisode ? '_s${season}e$episode' : '';
    final qualityPart = qualityValue > 0 ? '${qualityValue}p' : 'auto';
    final tmdbPart = tmdbId < 0 ? 'p${tmdbId.abs()}' : '$tmdbId';
    return '${safeName(title)}_$tmdbPart${episodePart}_${qualityPart}_$stamp.mp4';
  }

  static String subtitleFileName({
    required String videoPath,
    required String language,
    required String extension,
  }) {
    final stem = fileStem(videoPath);
    return '$stem.${safeName(language, maxLength: 12)}.$extension';
  }

  /// File name without directory or extension, using either separator.
  static String fileStem(String path) {
    final segments = path.split(RegExp(r'[\\/]'));
    final name = segments.isEmpty ? path : segments.last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String subtitleExtension(String url, String text) {
    final lower = url.toLowerCase();
    if (lower.contains('.vtt') ||
        lower.contains('format=vtt') ||
        text.trimLeft().startsWith('WEBVTT')) {
      return 'vtt';
    }
    return 'srt';
  }

  /// Detects an HTML/XML error page saved in place of media.
  static bool looksLikeMarkup(String prefix) {
    final normalized = prefix.trimLeft().toLowerCase();
    return normalized.startsWith('<!doctype') ||
        normalized.startsWith('<html') ||
        normalized.startsWith('<?xml') ||
        normalized.startsWith('<head') ||
        normalized.startsWith('<body');
  }

  static bool isWithinDirectory(String path, String directory) {
    if (path.isEmpty || directory.isEmpty) return false;
    final normalizedDirectory = directory.endsWith(Platform.pathSeparator) ||
            directory.endsWith('/')
        ? directory
        : '$directory${Platform.pathSeparator}';
    final normalizedPath = path.replaceAll('\\', '/');
    final normalizedBase = normalizedDirectory.replaceAll('\\', '/');
    return normalizedPath.startsWith(normalizedBase) &&
        !normalizedPath.contains('../');
  }

  /// Human explanation for an Android DownloadManager failure reason.
  static String failureMessage(int? reason) {
    if (reason == null) return 'The download did not finish.';
    if (reason >= 400 && reason <= 599) {
      if (reason == 401 || reason == 403) {
        return 'The provider refused this download (HTTP $reason). The stream '
            'link may have expired.';
      }
      if (reason == 404 || reason == 410) {
        return 'The provider no longer has this file (HTTP $reason).';
      }
      return 'The provider rejected the download (HTTP $reason).';
    }
    return switch (reason) {
      1001 => 'The download engine could not finish this download.',
      1002 => 'The file could not be written. Free up storage and try again.',
      1003 => 'The download could not be read back from storage.',
      1004 => 'The connection dropped during the download.',
      1005 => 'The download was too large for this network.',
      1006 => 'A file with this name already exists.',
      1007 => 'There is not enough free storage for this download.',
      1008 => 'The storage location became unavailable.',
      1009 => 'The server does not support resuming this download.',
      1010 => 'The provider redirected too many times.',
      1011 => 'The provider returned an unexpected HTTP response.',
      _ => 'The download did not finish (reason $reason).',
    };
  }

  /// DownloadManager cannot pause or resume arbitrary transfers, so Flix never
  /// shows pause/resume controls for it.
  static const bool supportsPauseResume = false;
}
