class CaptionTrack {
  final String id;
  final String language;
  final String languageName;
  final String url;
  final bool isDefault;

  CaptionTrack({
    required this.id,
    required this.language,
    required this.languageName,
    required this.url,
    this.isDefault = false,
  });

  factory CaptionTrack.fromJson(Map<String, dynamic> json) {
    final lang = (json['language'] ?? json['lang'] ?? 'en').toString();
    final name = (json['label'] ?? json['languageName'] ?? json['lanName'] ?? json['name'] ?? lang).toString();
    final url = (json['url'] ?? json['subtitleUrl'] ?? '').toString();
    final id = (json['id'] ?? '$lang-\${url.hashCode}').toString();
    final isDef = json['is_default'] == true || json['isDefault'] == true || json['default'] == true;

    return CaptionTrack(
      id: id,
      language: lang,
      languageName: name,
      url: url,
      isDefault: isDef,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'language': language,
    'languageName': languageName,
    'url': url,
    'isDefault': isDefault,
  };
}
