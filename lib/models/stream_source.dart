class StreamSource {
  final String url;
  final String resolution;
  final int qualityValue;
  final String format;
  final int sizeBytes;
  final int durationSeconds;
  final bool isPreview;
  final bool? verifiedFullLength;

  StreamSource({
    required this.url,
    required this.resolution,
    required this.qualityValue,
    required this.format,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.isPreview,
    this.verifiedFullLength,
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
      if (value != null)
        return (_parseInt(value) * entry.$2).clamp(0, 1 << 62).toInt();
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
      // Zarhosting's legacy bare `size` is reported in MB when small; values
      // beyond this threshold are treated as byte counts.
      final resolvedMultiplier = multiplier == 0
          ? (amount < 10_000_000 ? 1024 * 1024 : 1)
          : multiplier;
      return (amount * resolvedMultiplier).round().clamp(0, 1 << 62).toInt();
    }
    return _parseInt(raw).clamp(0, 1 << 62).toInt();
  }

  factory StreamSource.fromJson(Map<String, dynamic> json) {
    final rawUrl = json['url'] ??
        json['playback_url'] ??
        json['file'] ??
        json['stream_url'] ??
        '';
    final url = rawUrl.toString().trim();

    final resolution =
        (json['resolution'] ?? json['quality'] ?? json['label'] ?? '720p')
            .toString();
    final qualityMatch = RegExp(r'\d{3,4}').firstMatch(resolution);
    final qualityValue = qualityMatch == null
        ? 720
        : int.tryParse(qualityMatch.group(0)!) ?? 720;

    final rawFormat = (json['format'] ?? '').toString().trim();
    final lowerUrl = url.toLowerCase();
    final format = rawFormat.isNotEmpty
        ? rawFormat.toUpperCase()
        : lowerUrl.contains('.m3u8')
            ? 'HLS'
            : lowerUrl.contains('.mpd')
                ? 'DASH'
                : 'MP4';

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
        .toLowerCase();
    final previewMetadata = '$sourceLabel $resolution'.toLowerCase();
    final explicitPreview =
        json['is_preview'] == true || json['isPreview'] == true;
    final isPreview = explicitPreview ||
        [
          'preview',
          'trailer',
          'sample',
          'clip',
          'teaser',
          'mobile native',
        ].any(previewMetadata.contains);

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
      format: format,
      sizeBytes: sizeBytes,
      durationSeconds: duration,
      isPreview: isPreview,
      verifiedFullLength: verifiedFullLength,
    );
  }

  bool get isDownloadable =>
      !isPreview &&
      verifiedFullLength != false &&
      format.toUpperCase() == 'MP4' &&
      url.startsWith('https://');

  Map<String, dynamic> toJson() => {
        'url': url,
        'resolution': resolution,
        'qualityValue': qualityValue,
        'format': format,
        'sizeBytes': sizeBytes,
        'durationSeconds': durationSeconds,
        'isPreview': isPreview,
        'verifiedFullLength': verifiedFullLength,
      };
}
