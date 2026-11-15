/// Playback container families Flix can distinguish.
enum StreamFormat { mp4, hls, dash, other }

/// A validated provider playback source.
///
/// Nothing here is invented: quality, size, duration, codec and expiry come
/// from provider metadata or the URL, and stay "unknown" when the provider does
/// not supply them.
class StreamSource {
  final String url;
  final String resolution;
  final int qualityValue;
  final String format;
  final StreamFormat formatKind;
  final int sizeBytes;
  final int durationSeconds;
  final bool isPreview;
  final bool? verifiedFullLength;
  final String codec;
  final String sourceLabel;

  /// Extra headers this specific source needs (for example a signed DASH
  /// cookie). Merged over the standard playback profile by the player.
  final Map<String, String> headers;

  StreamSource({
    required this.url,
    required this.resolution,
    required this.qualityValue,
    required this.format,
    this.formatKind = StreamFormat.mp4,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.isPreview,
    this.verifiedFullLength,
    this.codec = '',
    this.sourceLabel = '',
    this.headers = const {},
  });

  static int _parseInt(dynamic value, [int fallback = 0]) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(value.toString());
    if (match == null) return fallback;
    return double.tryParse(match.group(0)!)?.round() ?? fallback;
  }

  static int _parseSizeBytes(Map<String, dynamic> json) {
    for (final key in [
      'size_bytes',
      'sizeBytes',
      'file_size_bytes',
      'filesize_bytes'
    ]) {
      final value = json[key];
      if (value != null) return _parseInt(value).clamp(0, 1 << 62).toInt();
    }

    for (final entry in [
      ('size_gb', 1024 * 1024 * 1024),
      ('size_mb', 1024 * 1024),
      ('size_kb', 1024),
    ]) {
      final value = json[entry.$1];
      if (value != null) {
        return (_parseInt(value) * entry.$2).clamp(0, 1 << 62).toInt();
      }
    }

    final raw = json['size'] ??
        json['file_size'] ??
        json['fileSize'] ??
        json['filesize'];
    if (raw == null) return 0;
    final text = raw.toString().trim().toLowerCase().replaceAll(',', '');
    final match =
        RegExp(r'^(\d+(?:\.\d+)?)\s*(b|bytes?|kb|kib|mb|mib|gb|gib)?$')
            .firstMatch(text);
    if (match != null) {
      final amount = double.tryParse(match.group(1)!) ?? 0;
      final unit = match.group(2) ?? '';
      final multiplier = switch (unit) {
        'gb' || 'gib' => 1024 * 1024 * 1024,
        'mb' || 'mib' => 1024 * 1024,
        'kb' || 'kib' => 1024,
        'b' || 'byte' || 'bytes' => 1,
        _ => 0,
      };
      // Zarhosting's legacy bare `size` is a byte count for video files.
      final resolvedMultiplier =
          multiplier == 0 ? (amount < 10000000 ? 1024 * 1024 : 1) : multiplier;
      return (amount * resolvedMultiplier).round().clamp(0, 1 << 62).toInt();
    }
    return _parseInt(raw).clamp(0, 1 << 62).toInt();
  }

  static bool isSecureUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        !uri.host.contains(' ');
  }

  static StreamFormat detectFormat(String url, [String declared = '']) {
    final normalized = declared.trim().toLowerCase();
    if (normalized.contains('m3u8') || normalized == 'hls') {
      return StreamFormat.hls;
    }
    if (normalized.contains('mpd') || normalized == 'dash') {
      return StreamFormat.dash;
    }
    if (normalized == 'mp4' || normalized == 'm4v') return StreamFormat.mp4;

    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.m3u8')) return StreamFormat.hls;
    if (path.endsWith('.mpd')) return StreamFormat.dash;
    if (path.endsWith('.mp4') || path.endsWith('.m4v')) {
      return StreamFormat.mp4;
    }
    if (normalized.isEmpty) return StreamFormat.other;
    return StreamFormat.other;
  }

  static String formatLabel(StreamFormat kind, String declared) {
    switch (kind) {
      case StreamFormat.hls:
        return 'HLS';
      case StreamFormat.dash:
        return 'DASH';
      case StreamFormat.mp4:
        return 'MP4';
      case StreamFormat.other:
        return declared.trim().isEmpty ? 'FILE' : declared.toUpperCase();
    }
  }

  /// Parses one provider source entry.
  ///
  /// Throws [FormatException] when the entry has no usable secure URL so the
  /// caller can count and skip invalid sources instead of silently accepting
  /// them.
  factory StreamSource.fromProviderJson(
    Map<String, dynamic> json, {
    Map<String, String> extraHeaders = const {},
  }) {
    final rawUrl = json['url'] ??
        json['playback_url'] ??
        json['playbackUrl'] ??
        json['file'] ??
        json['stream_url'];
    final url = rawUrl?.toString().trim() ?? '';
    if (!isSecureUrl(url)) {
      throw const FormatException('Provider source is not a secure URL');
    }

    final declaredFormat =
        (json['format'] ?? json['container'] ?? '').toString().trim();
    final formatKind = detectFormat(url, declaredFormat);

    final rawResolution =
        (json['resolution'] ?? json['quality'] ?? json['label'] ?? '')
            .toString()
            .trim();
    // DASH manifests expose a ladder ("1080,720,480") rather than one level.
    final ladder = (json['resolutions'] ?? '').toString().trim();
    String resolution = rawResolution;
    if (resolution.isEmpty && ladder.isNotEmpty) {
      final levels = ladder
          .split(',')
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toList()
        ..sort((a, b) => (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0));
      resolution = levels.isEmpty ? 'Auto' : '${levels.first}p';
    }
    if (resolution.isEmpty) resolution = 'Auto';
    final qualityMatch = RegExp(r'\d{3,4}').firstMatch(resolution);
    final qualityValue =
        qualityMatch == null ? 0 : int.tryParse(qualityMatch.group(0)!) ?? 0;

    final duration = _parseInt(json['duration_seconds'] ??
        json['duration_sec'] ??
        json['durationSeconds'] ??
        json['duration']);
    final sizeBytes = _parseSizeBytes(json);

    final sourceLabel = (json['source'] ??
            json['source_label'] ??
            json['sourceLabel'] ??
            json['source_name'] ??
            '')
        .toString()
        .trim();
    final explicitPreview = json['is_preview'] == true ||
        json['isPreview'] == true ||
        json['preview'] == true;
    // Only trustworthy preview markers. Duration is deliberately not used:
    // short films are legitimate full-length content.
    final previewLabel = sourceLabel.toLowerCase();
    final labelPreview = const [
      'preview',
      'trailer',
      'teaser',
      'sample',
    ].any(previewLabel.contains);
    final isPreview = explicitPreview || labelPreview;

    final explicitFullLength =
        json['verified_full_length'] ?? json['verifiedFullLength'];
    bool? verifiedFullLength;
    if (!isPreview) {
      if (explicitFullLength is bool) {
        verifiedFullLength = explicitFullLength;
      } else if (duration >= 300 || sizeBytes >= 50 * 1024 * 1024) {
        verifiedFullLength = true;
      }
    }

    return StreamSource(
      url: url,
      resolution: resolution,
      qualityValue: qualityValue,
      format: formatLabel(formatKind, declaredFormat),
      formatKind: formatKind,
      sizeBytes: sizeBytes,
      durationSeconds: duration,
      isPreview: isPreview,
      verifiedFullLength: verifiedFullLength,
      codec: (json['codec'] ?? json['codecName'] ?? '').toString().trim(),
      sourceLabel: sourceLabel,
      headers: extraHeaders,
    );
  }

  /// Backwards-compatible alias used by the existing UI and tests.
  factory StreamSource.fromJson(Map<String, dynamic> json) =>
      StreamSource.fromProviderJson(json);

  bool get isHls => formatKind == StreamFormat.hls;
  bool get isDash => formatKind == StreamFormat.dash;
  bool get isMp4 => formatKind == StreamFormat.mp4;
  bool get isAdaptive => isHls || isDash;
  bool get isPlayableFormat => formatKind != StreamFormat.other;

  bool get isDownloadable =>
      !isPreview &&
      verifiedFullLength != false &&
      isMp4 &&
      isSecureUrl(url);

  /// Human explanation for why a source cannot be saved offline. Null when it
  /// can be downloaded.
  String? get downloadUnsupportedReason {
    if (isPreview) return 'This provider entry is a trailer or preview.';
    if (isHls) {
      return 'This source is an HLS stream (segmented .m3u8). Flix can stream it '
          'but cannot save it as one offline file.';
    }
    if (isDash) {
      return 'This source is a DASH stream (segmented .mpd). Flix can stream it '
          'but cannot save it as one offline file.';
    }
    if (!isMp4) {
      return 'This source is a ${format.toUpperCase()} container that cannot be '
          'saved as a single offline MP4.';
    }
    if (verifiedFullLength == false) {
      return 'The provider marked this source as not full length.';
    }
    if (!isSecureUrl(url)) {
      return 'This source does not use a secure URL.';
    }
    return null;
  }

  String get sizeLabel {
    if (sizeBytes <= 0) return 'Size unknown';
    if (sizeBytes >= 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
  }

  String get displayLabel {
    final quality = resolution.isEmpty ? 'Auto' : resolution;
    return '$quality · ${format.toUpperCase()}';
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'resolution': resolution,
        'qualityValue': qualityValue,
        'format': format,
        'formatKind': formatKind.name,
        'sizeBytes': sizeBytes,
        'durationSeconds': durationSeconds,
        'isPreview': isPreview,
        'verifiedFullLength': verifiedFullLength,
        'codec': codec,
        'sourceLabel': sourceLabel,
      };
}
