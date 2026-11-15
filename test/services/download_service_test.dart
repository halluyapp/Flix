import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flix/models/caption_track.dart';
import 'package:flix/models/media_item.dart';
import 'package:flix/models/provider_match.dart';
import 'package:flix/models/stream_source.dart';
import 'package:flix/services/download_engine.dart';
import 'package:flix/services/download_service.dart';
import 'package:flix/services/stream_resolver.dart';
import 'package:flix/services/zarhosting_api_client.dart';
import 'package:flix/services/zarhosting_service.dart';

class _FakeEngine implements DownloadEngine {
  _FakeEngine(this.directory);

  final String directory;
  final List<DownloadEnqueueRequest> requests = [];
  final Map<int, DownloadEngineStatus> byId = {};
  int _nextId = 1;
  String contents = 'fake video bytes for offline playback';
  bool cancelled = false;

  @override
  bool get isSupported => true;

  @override
  bool get supportsPauseResume => false;

  @override
  Future<String> getDirectory() async => directory;

  @override
  Future<Map<String, dynamic>> enqueue(DownloadEnqueueRequest request) async {
    requests.add(request);
    final file = File('$directory${Platform.pathSeparator}${request.fileName}');
    await file.writeAsString(contents);
    final size = await file.length();
    final id = _nextId++;
    byId[id] = DownloadEngineStatus(
      id: id,
      status: 'completed',
      downloadedBytes: size,
      totalBytes: size,
    );
    return {'id': id, 'filePath': file.path};
  }

  @override
  Future<List<DownloadEngineStatus>> statuses(List<int> ids) async =>
      [for (final id in ids) if (byId.containsKey(id)) byId[id]!];

  @override
  Future<bool> cancel(int id) async {
    cancelled = true;
    byId.remove(id);
    return true;
  }

  @override
  Future<DownloadStorageInfo?> storageInfo() async =>
      const DownloadStorageInfo(
        totalBytes: 1000000000,
        freeBytes: 500000000,
        appBytes: 100000,
      );

  @override
  Future<bool> requestNotificationPermission() async => true;
}

MediaItem _movie() => MediaItem(
      id: 27205,
      title: 'Inception',
      overview: '',
      voteAverage: 8.4,
      releaseDate: '2010-07-16',
      mediaType: 'movie',
      genreIds: const [28],
    );

MediaItem _episode() => MediaItem(
      id: 1396,
      title: 'Breaking Bad',
      overview: '',
      voteAverage: 9.5,
      releaseDate: '2008-01-20',
      mediaType: 'tv',
      genreIds: const [18],
    );

ProviderMatch _match({bool isSeries = false}) => ProviderMatch(
      subjectId: isSeries ? '2001' : '1002',
      detailPath: isSeries ? 'breaking-bad' : 'inception',
      title: isSeries ? 'Breaking Bad' : 'Inception',
      year: isSeries ? 2008 : 2010,
      isSeries: isSeries,
      confidence: 1,
    );

StreamSource _mp4({int quality = 720}) => StreamSource(
      url: 'https://media.example.com/movie-$quality.mp4',
      resolution: '${quality}p',
      qualityValue: quality,
      format: 'MP4',
      formatKind: StreamFormat.mp4,
      sizeBytes: 0,
      durationSeconds: 5000,
      isPreview: false,
      verifiedFullLength: true,
    );

StreamSource _hls() => StreamSource(
      url: 'https://media.example.com/movie.m3u8',
      resolution: 'Auto',
      qualityValue: 0,
      format: 'HLS',
      formatKind: StreamFormat.hls,
      sizeBytes: 0,
      durationSeconds: 5000,
      isPreview: false,
      verifiedFullLength: true,
    );

ResolvedMediaStream _resolved(
  StreamSource source, {
  bool isSeries = false,
  List<CaptionTrack> captions = const [],
}) =>
    ResolvedMediaStream(
      sources: [source],
      captions: captions,
      match: _match(isSeries: isSeries),
      mediaHeaders: const {},
    );

Future<(DownloadService, _FakeEngine, Directory)> _setup() async {
  SharedPreferences.setMockInitialValues({});
  final directory = await Directory.systemTemp.createTemp('flix_download_test');
  final engine = _FakeEngine(directory.path);
  final resolver = StreamResolver(
    service: ZarhostingService(
      client: ZarhostingApiClient(
        client: MockClient((_) async => http.Response('{}', 500)),
        baseUrl: 'https://provider.example.com',
        maxAttempts: 1,
        sleep: (_) async {},
      ),
    ),
  );
  final service = DownloadService(resolver: resolver, engine: engine);
  return (service, engine, directory);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('downloads a movie, verifies the file and reports it offline-ready',
      () async {
    final (service, engine, directory) = await _setup();
    addTearDown(() async {
      service.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    final source = _mp4();
    final job = await service.startDownload(
      item: _movie(),
      season: 0,
      episode: 0,
      episodeTitle: '',
      resolved: _resolved(source),
      source: source,
      subtitleLanguages: const {},
    );

    expect(job.status, 'pending');
    expect(job.isComplete, isFalse);
    expect(service.downloads, hasLength(1));
    expect(engine.requests, hasLength(1));
    expect(engine.requests.single.url, source.url);
    expect(engine.requests.single.wifiOnly, isFalse);

    await service.refreshStatuses();

    final stored = service.downloads.single;
    expect(stored.isComplete, isTrue);
    expect(stored.verified, isTrue);
    expect(File(stored.filePath).existsSync(), isTrue);
    expect(service.completedDownloads, hasLength(1));
    expect(service.usedBytes, greaterThan(0));
  });

  test('prevents a duplicate download of the same quality', () async {
    final (service, engine, directory) = await _setup();
    addTearDown(() async {
      service.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    final source = _mp4();
    await service.startDownload(
      item: _movie(),
      season: 0,
      episode: 0,
      episodeTitle: '',
      resolved: _resolved(source),
      source: source,
      subtitleLanguages: const {},
    );
    await service.refreshStatuses();

    await expectLater(
      service.startDownload(
        item: _movie(),
        season: 0,
        episode: 0,
        episodeTitle: '',
        resolved: _resolved(source),
        source: source,
        subtitleLanguages: const {},
      ),
      throwsA(isA<DownloadConflictException>()),
    );
    expect(engine.requests, hasLength(1));
  });

  test('refuses to hand an HLS manifest to the single-file downloader',
      () async {
    final (service, engine, directory) = await _setup();
    addTearDown(() async {
      service.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    final source = _hls();
    await expectLater(
      service.startDownload(
        item: _movie(),
        season: 0,
        episode: 0,
        episodeTitle: '',
        resolved: _resolved(source),
        source: source,
        subtitleLanguages: const {},
      ),
      throwsA(isA<StateError>()),
    );
    expect(engine.requests, isEmpty);
    expect(service.downloads, isEmpty);
  });

  test('a subtitle failure never destroys a successful video download',
      () async {
    final (service, engine, directory) = await _setup();
    addTearDown(() async {
      service.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    final source = _mp4();
    final captions = [
      CaptionTrack(
        id: 'en',
        language: 'en',
        languageName: 'English',
        url: 'http://insecure.example.com/en.srt',
      ),
    ];
    final job = await service.startDownload(
      item: _movie(),
      season: 0,
      episode: 0,
      episodeTitle: '',
      resolved: _resolved(source, captions: captions),
      source: source,
      subtitleLanguages: const {'en'},
    );

    expect(job.subtitles, isEmpty);
    expect(job.subtitleLanguages, ['en']);
    expect(engine.requests, hasLength(1));
  });

  test('detects an HTML error page saved as a video', () async {
    final (service, engine, directory) = await _setup();
    engine.contents = '<!DOCTYPE html><html><body>403 Forbidden</body></html>';
    addTearDown(() async {
      service.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    final source = _mp4();
    await service.startDownload(
      item: _movie(),
      season: 0,
      episode: 0,
      episodeTitle: '',
      resolved: _resolved(source),
      source: source,
      subtitleLanguages: const {},
    );
    await service.refreshStatuses();

    final stored = service.downloads.single;
    expect(stored.isComplete, isFalse);
    expect(stored.status, 'corrupt');
    expect(stored.failureMessage, contains('web page'));
    expect(service.completedDownloads, isEmpty);
    expect(service.failedDownloads, hasLength(1));
  });

  test('deletes only the managed files for one download', () async {
    final (service, engine, directory) = await _setup();
    addTearDown(() async {
      service.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    final outside = File('${directory.path}${Platform.pathSeparator}keep.txt');
    await outside.writeAsString('unrelated');

    final source = _mp4();
    await service.startDownload(
      item: _movie(),
      season: 0,
      episode: 0,
      episodeTitle: '',
      resolved: _resolved(source),
      source: source,
      subtitleLanguages: const {},
    );
    await service.refreshStatuses();
    final job = service.downloads.single;
    expect(File(job.filePath).existsSync(), isTrue);

    await service.delete(job);

    expect(service.downloads, isEmpty);
    expect(File(job.filePath).existsSync(), isFalse);
    expect(outside.existsSync(), isTrue);
  });

  test('remembers the Wi-Fi-only preference', () async {
    final (service, engine, directory) = await _setup();
    addTearDown(() async {
      service.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    await service.setWifiOnly(true);
    expect(service.wifiOnly, isTrue);

    final source = _mp4();
    await service.startDownload(
      item: _episode(),
      season: 5,
      episode: 1,
      episodeTitle: 'Pilot',
      resolved: _resolved(source, isSeries: true),
      source: source,
      subtitleLanguages: const {},
    );

    expect(engine.requests.single.wifiOnly, isTrue);
    final job = service.downloads.single;
    expect(job.isEpisode, isTrue);
    expect(job.season, 5);
    expect(job.episode, 1);
  });

  test('recovery marks a download failed when its job disappears', () async {
    final (service, engine, directory) = await _setup();
    addTearDown(() async {
      service.dispose();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    final source = _mp4();
    await service.startDownload(
      item: _movie(),
      season: 0,
      episode: 0,
      episodeTitle: '',
      resolved: _resolved(source),
      source: source,
      subtitleLanguages: const {},
    );
    engine.byId.clear();
    await service.refreshStatuses();

    final stored = service.downloads.single;
    expect(stored.status, 'failed');
    expect(stored.failureMessage, contains('interrupted'));
  });
}
