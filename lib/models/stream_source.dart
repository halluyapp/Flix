class StreamSource {
  final String url;
  final String resolution;
  final int qualityValue;
  final String format;
  final int sizeBytes;
  final int durationSeconds;
  final bool isPreview;

  StreamSource({
    required this.url,
    required this.resolution,
    required this.qualityValue,
    required this.format,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.isPreview,
  });

  factory StreamSource.fromJson(Map<String, dynamic> json) {
    final url = (json['url'] ?? json['playback_url'] ?? json['file'] ?? '') as String;
    final res = (json['resolution'] ?? json['quality'] ?? json['label'] ?? '720p') as String;
    final qualityVal = int.tryParse(RegExp(r'\d+').firstMatch(res)?.group(0) ?? '') ?? 720;
    final format = url.contains('.m3u8') ? 'HLS' : 'MP4';
    final dur = (json['duration'] ?? json['duration_sec'] ?? 0) as int;
    final size = (json['size_bytes'] ?? json['size'] ?? 0) as int;
    final sourceLabel = (json['source'] ?? json['source_label'] ?? '').toString().toLowerCase();
    final isPreview = sourceLabel.contains('preview') || sourceLabel.contains('trailer') || dur < 300;

    return StreamSource(
      url: url,
      resolution: res,
      qualityValue: qualityVal,
      format: format,
      sizeBytes: size,
      durationSeconds: dur,
      isPreview: isPreview,
    );
  }
}
