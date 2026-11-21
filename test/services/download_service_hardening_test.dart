import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flix/models/media_item.dart';
import 'package:flix/models/provider_match.dart';
import 'package:flix/models/stream_source.dart';
import 'package:flix/services/download_engine.dart';
import 'package:flix/services/download_service.dart';
import 'package:flix/services/media_probe.dart';
import 'package:flix/services/stream_resolver.dart';
import 'package:flix/services/zarhosting_api_client.dart';
import 'package:flix/services/zarhosting_service.dart';

/// Every source the download fallback would try (chosen + alternatives).
class _FakeEngine implements DownloadEngine {
  _FakeEngine(this.directory);

  final String directory;
  final List<DownloadEnqueueRequest> requests = [];
  final Map<int, DownloadEngineStatus> byId = {};
  int _nextId = 1;
  int enqueueCalls = 0;
  bool hangEnqueue = false;
  final Completer<Map<String, dynamic>> hungEnqueue =
      Completer<Map<String, dynamic>>();

  @override
  bool get isSupported => true;

  @override
  bool get supportsPauseResume => false;

  @override
  Future<String> getDirectory() async => directory;

  @override
  Future<Map<String, dynamic>> enqueue(DownloadEnqueueRequest request) async {
    enqueueCalls++;
    if (hangEnqueue) {
      // A never-ending platform channel: the service must bound the wait.
      return hungEnqueue.future;
    }
    requests.add(request);
    final file = File('$directory${Platform.pathSeparator}${request.fileName}');
    await file.writeAsString('fake video bytes');
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
  Future<bool> cancel(int id) async => true;

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

StreamSource _mp4({int quality = 720, String? url}) => StreamSource(
      url: url ?? 'https://media.example.com/movie-$quality.mp4',
      resolution: '${quality}p',
      qualityValue: quality,
      format: 'MP4',
      formatKind: StreamFormat.mp4,
      sizeBytes: 0,
      durationSeconds: 5000,
      isPreview: false,
      verifiedFullLength: true,
    );

ProviderMatch _match() => ProviderMatch(
      subjectId: '1002',
      detailPath: 'inception',
      title: 'Inception',
      year: 2010,
      isSeries: false,
      confidence: 1,
    );

ResolvedMediaStream _resolved(StreamSource first, List<StreamSource> all) {
  return ResolvedMediaStream(
    sources: all,
    captions: const [],
    match: _match(),
    mediaHeaders: const {},
  );
}

DownloadService _service(
  _FakeEngine engine, {
  required http.Client probeClient,
  Duration engineBudget = const Duration(seconds: 5),
}) =>
    DownloadService(
      resolver: StreamResolver(
        service: ZarhostingService(
          client: ZarhostingApiClient(
            client: MockClient((_) async => http.Response('{}', 500)),
            baseUrl: 'https://provider.example.com',
            maxAttempts: 1,
            sleep: (_) async {},
          ),
        ),
      ),
      engine: engine,
      probe: MediaProbe(
        client: probeClient,
        retryDelay: Duration.zero,
      ),
      engineBudget: engineBudget,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('download initiation hardening', () {
    test('concurrent calls for the same media reuse one engine request',
        () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('flix_dedup_test');
      addTearDown(() async {
        if (directory.existsSync()) await directory.delete(recursive: true);
      });
      final engine = _FakeEngine(directory.path);
      final service = _service(
        engine,
        probeClient: MockClient((_) async => http.Response('', 206)),
      );
      addTearDown(service.dispose);

      final source = _mp4();
      final first = service.startDownload(
        item: _movie(),
        season: 0,
        episode: 0,
        episodeTitle: '',
        resolved: _resolved(source, [source]),
        source: source,
        subtitleLanguages: const {},
      );
      final second = service.startDownload(
        item: _movie(),
        season: 0,
        episode: 0,
        episodeTitle: '',
        resolved: _resolved(source, [source]),
        source: source,
        subtitleLanguages: const {},
      );
      final results = await Future.wait([first, second]);

      expect(results[0].key, results[1].key);
      expect(engine.requests, hasLength(1));
    });

    test('a hung engine surfaces an error and releases the in-flight slot',
        () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('flix_hang_test');
      addTearDown(() async {
        if (directory.existsSync()) await directory.delete(recursive: true);
      });
      final engine = _FakeEngine(directory.path)
        ..hangEnqueue = true;
      final service = _service(
        engine,
        probeClient: MockClient((_) async => http.Response('', 206)),
        engineBudget: const Duration(milliseconds: 250),
      );
      addTearDown(service.dispose);

      final source = _mp4();
      await expectLater(
        service.startDownload(
          item: _movie(),
          season: 0,
          episode: 0,
          episodeTitle: '',
          resolved: _resolved(source, [source]),
          source: source,
          subtitleLanguages: const {},
        ),
        throwsA(isA<StateError>()),
      );
      expect(engine.enqueueCalls, 1);
      // Let the in-flight cleanup microtask run before the retry.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // A hung attempt must not wedge the queue: the next attempt runs.
      engine.hangEnqueue = false;
      await service.startDownload(
        item: _movie(),
        season: 0,
        episode: 0,
        episodeTitle: '',
        resolved: _resolved(source, [source]),
        source: source,
        subtitleLanguages: const {},
      );
      expect(engine.enqueueCalls, 2);
      expect(service.downloads, hasLength(1));
    });

    test('a blocked chosen source falls back to a reachable candidate',
        () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('flix_fallback_test');
      addTearDown(() async {
        if (directory.existsSync()) await directory.delete(recursive: true);
      });
      final engine = _FakeEngine(directory.path);
      final blocked = _mp4(quality: 1080, url: 'https://media.example.com/1080p.mp4');
      final reachable = _mp4(quality: 720, url: 'https://media.example.com/720p.mp4');
      final service = _service(
        engine,
        probeClient: MockClient((request) async {
          return request.url.path == '/1080p.mp4'
              ? http.Response('', 403)
              : http.Response('', 206);
        }),
      );
      addTearDown(service.dispose);

      final resolved = _resolved(blocked, [blocked, reachable]);
      final job = await service.startDownload(
        item: _movie(),
        season: 0,
        episode: 0,
        episodeTitle: '',
        resolved: resolved,
        source: blocked,
        subtitleLanguages: const {},
      );

      expect(job.resolution, '720p');
      expect(engine.requests.single.url, reachable.url);
    });
  });
}
