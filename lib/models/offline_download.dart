import 'media_item.dart';

class OfflineSubtitle {
  final String language;
  final String languageName;
  final String path;
  final int sizeBytes;

  const OfflineSubtitle({
    required this.language,
    required this.languageName,
    required this.path,
    this.sizeBytes = 0,
  });

  Map<String, dynamic> toJson() => {
        'language': language,
        'languageName': languageName,
        'path': path,
        'sizeBytes': sizeBytes,
      };

  factory OfflineSubtitle.fromJson(Map<String, dynamic> json) => OfflineSubtitle(
        language: (json['language'] ?? 'und').toString(),
        languageName:
            (json['languageName'] ?? json['language'] ?? 'Subtitles').toString(),
        path: (json['path'] ?? '').toString(),
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      );

  bool get isUsable => path.isNotEmpty;
}

/// One managed offline video (a movie or a single TV episode) plus the local
/// files that belong to it.
class OfflineDownload {
  final String key;
  final int nativeId;
  final MediaItem item;
  final int season;
  final int episode;
  final String episodeTitle;
  final String resolution;
  final int qualityValue;
  final String filePath;
  final List<OfflineSubtitle> subtitles;

  /// Languages the viewer selected at download time, kept so a subtitle retry
  /// does not need the video to be downloaded again.
  final List<String> subtitleLanguages;

  /// Why a selected language is not saved, keyed by language code. Stored so
  /// the library can show it and a retry can be offered without re-downloading
  /// the video. Empty when every selected subtitle is saved.
  final Map<String, String> subtitleIssues;

  /// pending | running | paused | completed | failed | cancelled | corrupt
  final String status;
  final int downloadedBytes;
  final int totalBytes;

  /// Size the provider declared before the transfer started (0 when unknown).
  final int expectedBytes;
  final DateTime createdAt;
  final int profileIndex;
  final int? failureReason;
  final String? failureMessage;

  /// True only after the local file passed existence, size and content checks.
  final bool verified;
  final String format;

  const OfflineDownload({
    required this.key,
    required this.nativeId,
    required this.item,
    required this.season,
    required this.episode,
    required this.episodeTitle,
    required this.resolution,
    this.qualityValue = 0,
    required this.filePath,
    required this.subtitles,
    this.subtitleLanguages = const [],
    this.subtitleIssues = const {},
    required this.status,
    required this.downloadedBytes,
    required this.totalBytes,
    this.expectedBytes = 0,
    required this.createdAt,
    this.profileIndex = 0,
    this.failureReason,
    this.failureMessage,
    this.verified = false,
    this.format = 'MP4',
  });

  bool get isEpisode => item.mediaType == 'tv';
  bool get isComplete => status == 'completed' && verified;
  bool get isProcessing =>
      status == 'pending' || status == 'running' || status == 'paused';
  bool get isFailed =>
      status == 'failed' || status == 'cancelled' || status == 'corrupt';
  bool get isOfflineReady => isComplete;
  bool get hasSubtitles => subtitles.where((entry) => entry.isUsable).isNotEmpty;

  double get progress {
    if (totalBytes <= 0) return 0;
    return (downloadedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  }

  int get sizeOnDisk {
    var total = downloadedBytes;
    for (final subtitle in subtitles) {
      total += subtitle.sizeBytes;
    }
    return total;
  }

  String get displayTitle => isEpisode
      ? '${item.title} · S${season.toString().padLeft(2, '0')}:E${episode.toString().padLeft(2, '0')}${episodeTitle.isEmpty ? '' : ' · $episodeTitle'}'
      : item.title;

  String get episodeLabel => isEpisode
      ? 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
      : 'Film';

  /// Identity used for duplicate prevention (ignores quality).
  String get mediaIdentity =>
      '${item.mediaType}_${item.id}_${isEpisode ? season : 0}_${isEpisode ? episode : 0}';

  String get downloadIdentity => '${mediaIdentity}_$qualityValue';

  /// Selected subtitle languages that have no saved file.
  List<String> get missingSubtitleLanguages {
    final saved = subtitles
        .where((subtitle) => subtitle.isUsable)
        .map((subtitle) => subtitle.language)
        .toSet();
    return subtitleLanguages
        .where((language) => !saved.contains(language))
        .toList(growable: false);
  }

  /// True for a finished video whose selected subtitles are not all saved.
  bool get hasMissingSubtitles =>
      isComplete && missingSubtitleLanguages.isNotEmpty;

  String get subtitleSummary {
    if (subtitles.isEmpty) {
      return subtitleLanguages.isEmpty
          ? 'No subtitles saved'
          : 'Subtitles not saved';
    }
    final names = subtitles
        .where((subtitle) => subtitle.isUsable)
        .map((subtitle) => subtitle.languageName)
        .toSet()
        .join(', ');
    final missing = missingSubtitleLanguages.length;
    if (missing == 0) return names.isEmpty ? 'No subtitles saved' : names;
    return names.isEmpty ? '$missing missing' : '$names · $missing missing';
  }

  String get statusLabel => switch (status) {
        'pending' => 'Queued',
        'running' => 'Downloading',
        'paused' => 'Paused',
        'completed' => verified ? 'Downloaded' : 'Verifying',
        'failed' => 'Failed',
        'cancelled' => 'Cancelled',
        'corrupt' => 'File problem',
        _ => 'Unknown',
      };

  OfflineDownload copyWith({
    int? nativeId,
    String? filePath,
    List<OfflineSubtitle>? subtitles,
    List<String>? subtitleLanguages,
    Map<String, String>? subtitleIssues,
    String? status,
    int? downloadedBytes,
    int? totalBytes,
    int? expectedBytes,
    int? profileIndex,
    int? failureReason,
    String? failureMessage,
    bool clearFailure = false,
    bool? verified,
    String? resolution,
  }) =>
      OfflineDownload(
        key: key,
        nativeId: nativeId ?? this.nativeId,
        item: item,
        season: season,
        episode: episode,
        episodeTitle: episodeTitle,
        resolution: resolution ?? this.resolution,
        qualityValue: qualityValue,
        filePath: filePath ?? this.filePath,
        subtitles: subtitles ?? this.subtitles,
        subtitleLanguages: subtitleLanguages ?? this.subtitleLanguages,
        subtitleIssues: subtitleIssues ?? this.subtitleIssues,
        status: status ?? this.status,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        expectedBytes: expectedBytes ?? this.expectedBytes,
        createdAt: createdAt,
        profileIndex: profileIndex ?? this.profileIndex,
        failureReason: failureReason ?? this.failureReason,
        failureMessage:
            clearFailure ? null : (failureMessage ?? this.failureMessage),
        verified: verified ?? this.verified,
        format: format,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'nativeId': nativeId,
        'item': item.toJson(),
        'season': season,
        'episode': episode,
        'episodeTitle': episodeTitle,
        'resolution': resolution,
        'qualityValue': qualityValue,
        'filePath': filePath,
        'subtitles': subtitles.map((subtitle) => subtitle.toJson()).toList(),
        'subtitleLanguages': subtitleLanguages,
        'subtitleIssues': subtitleIssues,
        'status': status,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'expectedBytes': expectedBytes,
        'createdAt': createdAt.toIso8601String(),
        'profileIndex': profileIndex,
        'failureReason': failureReason,
        'failureMessage': failureMessage,
        'verified': verified,
        'format': format,
      };

  static Map<String, String> _issuesFrom(dynamic raw) {
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        entry.key.toString(): entry.value.toString(),
    };
  }

  factory OfflineDownload.fromJson(Map<String, dynamic> json) {
    final rawItem = json['item'];
    if (rawItem is! Map) {
      throw const FormatException('Invalid offline title metadata');
    }
    final rawSubtitles = json['subtitles'];
    final rawLanguages = json['subtitleLanguages'];
    return OfflineDownload(
      key: (json['key'] ?? '').toString(),
      nativeId: (json['nativeId'] as num?)?.toInt() ?? 0,
      item: MediaItem.fromJson(Map<String, dynamic>.from(rawItem)),
      season: (json['season'] as num?)?.toInt() ?? 0,
      episode: (json['episode'] as num?)?.toInt() ?? 0,
      episodeTitle: (json['episodeTitle'] ?? '').toString(),
      resolution: (json['resolution'] ?? 'Auto').toString(),
      qualityValue: (json['qualityValue'] as num?)?.toInt() ?? 0,
      filePath: (json['filePath'] ?? '').toString(),
      subtitles: rawSubtitles is List
          ? rawSubtitles
              .whereType<Map>()
              .map((value) =>
                  OfflineSubtitle.fromJson(Map<String, dynamic>.from(value)))
              .toList()
          : const [],
      subtitleLanguages: rawLanguages is List
          ? rawLanguages.map((value) => value.toString()).toList()
          : const [],
      subtitleIssues: _issuesFrom(json['subtitleIssues']),
      status: (json['status'] ?? 'unknown').toString(),
      downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      expectedBytes: (json['expectedBytes'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
      profileIndex: (json['profileIndex'] as num?)?.toInt() ?? 0,
      failureReason: (json['failureReason'] as num?)?.toInt(),
      failureMessage: json['failureMessage']?.toString(),
      verified: json['verified'] == true,
      format: (json['format'] ?? 'MP4').toString(),
    );
  }
}
