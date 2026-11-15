/// One subtitle track returned by the provider.
///
/// Zarhosting labels tracks with `lan`/`lanName`; older mirrors use
/// `language`/`label`. All observed spellings are accepted so tracks are never
/// mislabelled as English by default.
class CaptionTrack {
  final String id;
  final String language;
  final String languageName;
  final String url;
  final bool isDefault;
  final int sizeBytes;

  CaptionTrack({
    required this.id,
    required this.language,
    required this.languageName,
    required this.url,
    this.isDefault = false,
    this.sizeBytes = 0,
  });

  static int _parseSize(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt().clamp(0, 1 << 62);
    final match = RegExp(r'\d+').firstMatch(value.toString());
    return (int.tryParse(match?.group(0) ?? '') ?? 0).clamp(0, 1 << 62);
  }

  factory CaptionTrack.fromJson(Map<String, dynamic> json) {
    final language = (json['lan'] ??
            json['language'] ??
            json['lang'] ??
            json['srclang'] ??
            json['languageCode'] ??
            'und')
        .toString()
        .trim()
        .toLowerCase();
    final name = (json['lanName'] ??
            json['label'] ??
            json['languageName'] ??
            json['language_name'] ??
            json['name'] ??
            '')
        .toString()
        .trim();
    final url = (json['url'] ??
            json['subtitleUrl'] ??
            json['subtitle_url'] ??
            json['file'] ??
            '')
        .toString()
        .trim();
    final id = (json['id'] ?? '$language-${url.hashCode}').toString();
    final isDefault = json['is_default'] == true ||
        json['isDefault'] == true ||
        json['default'] == true;

    return CaptionTrack(
      id: id,
      language: language.isEmpty ? 'und' : language,
      languageName: name.isEmpty ? language.toUpperCase() : name,
      url: url,
      isDefault: isDefault,
      sizeBytes: _parseSize(json['size'] ?? json['size_bytes']),
    );
  }

  bool get isSecure => Uri.tryParse(url)?.scheme == 'https';

  bool get isSubtitleFormat {
    final lower = url.toLowerCase();
    return lower.contains('.srt') ||
        lower.contains('.vtt') ||
        lower.contains('.webvtt') ||
        lower.contains('format=srt') ||
        lower.contains('format=vtt');
  }

  String get extension {
    final lower = url.toLowerCase();
    if (lower.contains('.vtt') || lower.contains('format=vtt')) return 'vtt';
    return 'srt';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'lan': language,
        'lanName': languageName,
        'url': url,
        'isDefault': isDefault,
        'size': sizeBytes,
      };

  factory CaptionTrack.fromStorageJson(Map<String, dynamic> json) =>
      CaptionTrack.fromJson(json);
}
