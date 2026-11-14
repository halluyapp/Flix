import 'media_item.dart';

class OfflineSubtitle {
  final String language;
  final String languageName;
  final String path;

  const OfflineSubtitle(
      {required this.language, required this.languageName, required this.path});

  Map<String, dynamic> toJson() => {
        'language': language,
        'languageName': languageName,
        'path': path,
      };

  factory OfflineSubtitle.fromJson(Map<String, dynamic> json) =>
      OfflineSubtitle(
        language: (json['language'] ?? 'und').toString(),
        languageName: (json['languageName'] ?? json['language'] ?? 'Subtitles')
            .toString(),
        path: (json['path'] ?? '').toString(),
      );
}

class OfflineDownload {
  final String key;
  final int nativeId;
  final MediaItem item;
  final int season;
  final int episode;
  final String episodeTitle;
  final String resolution;
  final String filePath;
  final List<OfflineSubtitle> subtitles;
  final String status;
  final int downloadedBytes;
  final int totalBytes;
  final DateTime createdAt;
  final int profileIndex;
  final int? failureReason;

  const OfflineDownload({
    required this.key,
    required this.nativeId,
    required this.item,
    required this.season,
    required this.episode,
    required this.episodeTitle,
    required this.resolution,
    required this.filePath,
    required this.subtitles,
    required this.status,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.createdAt,
    this.profileIndex = 0,
    this.failureReason,
  });

  bool get isEpisode => item.mediaType == 'tv';
  bool get isComplete => status == 'completed';
  bool get isActive =>
      status == 'pending' || status == 'running' || status == 'paused';
  double get progress => totalBytes > 0
      ? (downloadedBytes / totalBytes).clamp(0, 1).toDouble()
      : 0;
  String get displayTitle => isEpisode
      ? '${item.title} · S${season.toString().padLeft(2, '0')}:E${episode.toString().padLeft(2, '0')}${episodeTitle.isEmpty ? '' : ' · $episodeTitle'}'
      : item.title;

  OfflineDownload copyWith({
    int? nativeId,
    String? filePath,
    List<OfflineSubtitle>? subtitles,
    String? status,
    int? downloadedBytes,
    int? totalBytes,
    int? profileIndex,
    int? failureReason,
  }) =>
      OfflineDownload(
        key: key,
        nativeId: nativeId ?? this.nativeId,
        item: item,
        season: season,
        episode: episode,
        episodeTitle: episodeTitle,
        resolution: resolution,
        filePath: filePath ?? this.filePath,
        subtitles: subtitles ?? this.subtitles,
        status: status ?? this.status,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        createdAt: createdAt,
        profileIndex: profileIndex ?? this.profileIndex,
        failureReason: failureReason ?? this.failureReason,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'nativeId': nativeId,
        'item': item.toJson(),
        'season': season,
        'episode': episode,
        'episodeTitle': episodeTitle,
        'resolution': resolution,
        'filePath': filePath,
        'subtitles': subtitles.map((subtitle) => subtitle.toJson()).toList(),
        'status': status,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'createdAt': createdAt.toIso8601String(),
        'profileIndex': profileIndex,
        'failureReason': failureReason,
      };

  factory OfflineDownload.fromJson(Map<String, dynamic> json) {
    final rawItem = json['item'];
    if (rawItem is! Map)
      throw const FormatException('Invalid offline title metadata');
    final rawSubtitles = json['subtitles'];
    return OfflineDownload(
      key: (json['key'] ?? '').toString(),
      nativeId: (json['nativeId'] as num?)?.toInt() ?? 0,
      item: MediaItem.fromJson(Map<String, dynamic>.from(rawItem)),
      season: (json['season'] as num?)?.toInt() ?? 0,
      episode: (json['episode'] as num?)?.toInt() ?? 0,
      episodeTitle: (json['episodeTitle'] ?? '').toString(),
      resolution: (json['resolution'] ?? 'Auto').toString(),
      filePath: (json['filePath'] ?? '').toString(),
      subtitles: rawSubtitles is List
          ? rawSubtitles
              .whereType<Map>()
              .map((value) =>
                  OfflineSubtitle.fromJson(Map<String, dynamic>.from(value)))
              .toList()
          : const [],
      status: (json['status'] ?? 'unknown').toString(),
      downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
      profileIndex: (json['profileIndex'] as num?)?.toInt() ?? 0,
      failureReason: (json['failureReason'] as num?)?.toInt(),
    );
  }
}
