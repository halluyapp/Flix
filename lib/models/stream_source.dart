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
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  factory StreamSource.fromJson(Map<String, dynamic> json) {
    final rawUrl = json['url'] ?? json['playback_url'] ?? json['file'] ?? json['stream_url'] ?? '';
    final url = rawUrl.toString();

    final res = (json['resolution'] ?? json['quality'] ?? json['label'] ?? '720p').toString();
    final qualityMatch = RegExp(r'\d{3,4}').firstMatch(res);
    final qualityVal = qualityMatch != null ? int.tryParse(qualityMatch.group(0)!) ?? 720 : 720;

    final format = (json['format'] ?? (url.contains('.m3u8') ? 'HLS' : (url.contains('.mpd') ? 'DASH' : 'MP4'))).toString();
    final dur = _parseInt(json['duration'] ?? json['duration_sec'] ?? json['durationSeconds']);
    final size = _parseInt(json['size_bytes'] ?? json['size'] ?? json['sizeBytes']);

    final sourceLabel = (json['source'] ?? json['source_label'] ?? json['sourceLabel'] ?? '').toString().toLowerCase();
    
    // Preview heuristics conforming to Hallyu-TV spec:
    // Labels containing preview/trailer/sample/clip, or positive duration under 180 seconds.
    final looksPreview = sourceLabel.contains('preview') ||
        sourceLabel.contains('trailer') ||
        sourceLabel.contains('sample') ||
        sourceLabel.contains('clip') ||
        sourceLabel.contains('mobile native');
    final isPreview = looksPreview || (dur > 0 && dur < 180);

    // Verified full-length: duration > 300s or size > 50MB
    bool? verifiedFull;
    if (!isPreview) {
      if (dur > 300 || size > 50 * 1024 * 1024) {
        verifiedFull = true;
      } else if (dur == 0 && size == 0) {
        verifiedFull = null; // Unverified but selectable
      } else {
        verifiedFull = false;
      }
    }

    return StreamSource(
      url: url,
      resolution: res,
      qualityValue: qualityVal,
      format: format,
      sizeBytes: size,
      durationSeconds: dur,
      isPreview: isPreview,
      verifiedFullLength: verifiedFull,
    );
  }

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
