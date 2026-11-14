class CaptionTrack {
  final String id;
  final String language;
  final String languageName;
  final String url;

  CaptionTrack({
    required this.id,
    required this.language,
    required this.languageName,
    required this.url,
  });

  factory CaptionTrack.fromJson(Map<String, dynamic> json) {
    return CaptionTrack(
      id: (json['id'] ?? '') as String,
      language: (json['lan'] ?? json['language'] ?? 'en') as String,
      languageName: (json['lanName'] ?? json['languageName'] ?? 'English') as String,
      url: (json['url'] ?? json['subtitleUrl'] ?? '') as String,
    );
  }
}
