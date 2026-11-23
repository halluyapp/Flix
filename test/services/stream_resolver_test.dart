import 'dart:io';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flix/core/provider/provider_failures.dart';
import 'package:flix/models/caption_load.dart';
import 'package:flix/models/media_item.dart';
import 'package:flix/models/provider_match.dart';
import 'package:flix/services/moviebox_api_client.dart';
import 'package:flix/services/moviebox_service.dart';
import 'package:flix/services/stream_resolver.dart';

http.Response _json(String body, [int status = 200]) => http.Response.bytes(
      utf8.encode(body),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

MediaItem _movie() => MediaItem(
      id: 27205,
      title: 'Inception',
      originalTitle: 'Inception',
      overview: '',
      voteAverage: 8.4,
      releaseDate: '2010-07-16',
      mediaType: 'movie',
      genreIds: const [28],
    );

MediaItem _show() => MediaItem(
      id: 1396,
      title: 'Breaking Bad',
      originalTitle: 'Breaking Bad',
      overview: '',
      voteAverage: 9.5,
      releaseDate: '2008-01-20',
      mediaType: 'tv',
      genreIds: const [18],
    );

class _Harness {
  final List<Uri> requests = [];
  late final StreamResolver resolver;

  _Harness({
    String? search,
    String? stream,
    String? captions,
    int captionStatus = 200,
    int streamStatus = 200,
  }) {
    final mock = MockClient((request) async {
      requests.add(request.url);
      final path = request.url.path;
      if (path.endsWith('/home')) {
        return http.Response(
          '{"code":0,"data":{}}',
          200,
          headers: {'x-user': '{"token":"test-token","userId":"1"}'},
        );
      }
      if (path.endsWith('/search')) {
        return _json(
          search ?? _fixture('provider_search_movie.json'),
          200,
        );
      }
      if (path.endsWith('/caption') || path.endsWith('/captions')) {
        return captionStatus == 200
            ? _json(captions ?? _fixture('provider_captions.json'), 200)
            : _json('{"error":"upstream_error"}', captionStatus);
      }
      if (path.endsWith('/play') || path.contains('/stream/')) {
        return streamStatus == 200
            ? _json(stream ?? _fixture('provider_stream_movie.json'), 200)
            : _json('{"error":"upstream_error"}', streamStatus);
      }
      return _json('{}', 404);
    });

    resolver = StreamResolver(
      service: MovieBoxService(
        client: MovieBoxApiClient(
          client: mock,
          baseUrl: 'https://h5-api.aoneroom.com/wefeed-h5api-bff',
          defaultTimeout: const Duration(seconds: 1),
          sleep: (_) async {},
          initialToken: const GuestToken(token: 'fixture-jwt'),
        ),
      ),
    );
  }

  int count(String fragment) =>
      requests.where((uri) => uri.path.contains(fragment)).length;

  /// Counts stream requests only, excluding the `/caption` endpoint.
  int countStreams() => requests
      .where((uri) =>
          (uri.path.endsWith('/play') || uri.path.contains('/stream/')) &&
          !uri.path.endsWith('/caption') &&
          !uri.path.endsWith('/captions'))
      .length;

  Uri lastStream() => requests.lastWhere((uri) =>
      (uri.path.endsWith('/play') || uri.path.contains('/stream/')) &&
      !uri.path.endsWith('/caption') &&
      !uri.path.endsWith('/captions'));

  Uri last(String fragment) =>
      requests.lastWhere((uri) => uri.path.contains(fragment));
}

void main() {
  group('StreamResolver movie playback', () {
    test('resolves playable MP4 sources and provider captions', () async {
      final harness = _Harness();
      final resolution = await harness.resolver.resolve(item: _movie());

      expect(resolution.isSuccess, isTrue);
      final stream = resolution.stream!;
      expect(stream.match.subjectId, '6391474290696802080');
      expect(stream.match.detailPath, 'inception-e1BOR6f19C7');
      expect(stream.selectableSources, hasLength(4));
      expect(stream.downloadSources, hasLength(2));
      expect(stream.downloadSources.first.resolution, '1080p');
      expect(stream.streamingOnlySources, hasLength(2));
      expect(stream.captions.map((caption) => caption.language), ['ar', 'en']);
      expect(
        stream.captions.first.languageName,
        'العربية',
      );
      expect(stream.bestSource!.format, 'MP4');
    });

    test('sends the slug as detailPath and se=0 ep=0 for movie play', () async {
      final harness = _Harness();
      await harness.resolver.resolve(item: _movie());

      final streamRequest = harness.lastStream();
      expect(streamRequest.queryParameters['detailPath'],
          'inception-e1BOR6f19C7');
      expect(streamRequest.queryParameters['se'], '0');
      expect(streamRequest.queryParameters['ep'], '0');
    });

    test('dash sources keep their signed cookie header', () async {
      final harness = _Harness();
      final resolution = await harness.resolver.resolve(item: _movie());
      final dash = resolution.stream!.sources
          .firstWhere((source) => source.url.contains('index_web.mpd'));
      expect(dash.isDash, isTrue);
      expect(dash.headers['Cookie'], 'Edge-Cache-Cookie=fixture');
      expect(dash.isDownloadable, isFalse);
    });
  });

  group('StreamResolver episode playback', () {
    test('sends the provider se/ep contract for a TV episode', () async {
      final harness = _Harness(
        search: _fixture('provider_search_tv.json'),
        stream: _fixture('provider_stream_episode.json'),
      );

      final resolution = await harness.resolver.resolve(
        item: _show(),
        season: 5,
        episode: 1,
      );

      expect(resolution.isSuccess, isTrue);
      final request = harness.lastStream();
      expect(request.path, endsWith('/play'));
      expect(request.queryParameters['subjectId'],
          '1382465867459478920');
      expect(request.queryParameters['detailPath'],
          'breaking-bad-hindi-mz0TdRUH7E1');
      expect(request.queryParameters['se'], '5');
      expect(request.queryParameters['ep'], '1');
      expect(resolution.stream!.downloadSources, hasLength(3));
    });

    test('a TV episode without a season fails with a typed error', () async {
      final harness = _Harness(
        search: _fixture('provider_search_tv.json'),
        stream: _fixture('provider_stream_episode.json'),
      );
      final resolution = await harness.resolver.resolve(item: _show());
      expect(resolution.isSuccess, isFalse);
      expect(
        resolution.errorType,
        ProviderErrorType.missingProviderIdentifier,
      );
    });
  });

  group('StreamResolver caching and concurrency', () {
    test('concurrent duplicate resolutions share one provider request',
        () async {
      final harness = _Harness();
      await Future.wait([
        harness.resolver.resolve(item: _movie()),
        harness.resolver.resolve(item: _movie()),
      ]);
      expect(harness.countStreams(), 1);
      expect(harness.count('/search'), 1);
    });

    test('cached results reuse the match but drop signed URLs on invalidation',
        () async {
      final harness = _Harness();
      await harness.resolver.resolve(item: _movie());
      harness.resolver.invalidate(item: _movie());
      final second = await harness.resolver.resolve(item: _movie());

      expect(second.isSuccess, isTrue);
      expect(harness.count('/search'), 1);
      expect(harness.countStreams(), 2);
    });

    test('forceRefresh re-requests the stream', () async {
      final harness = _Harness();
      await harness.resolver.resolve(item: _movie());
      await harness.resolver.resolve(item: _movie(), forceRefresh: true);
      expect(harness.countStreams(), 2);
    });
  });

  group('StreamResolver failures', () {
    test('reports a typed no-match without inventing a source', () async {
      final harness = _Harness(search: '{"items":[]}');
      final resolution = await harness.resolver.resolve(item: _movie());
      expect(resolution.isSuccess, isFalse);
      expect(resolution.errorType, ProviderErrorType.noProviderMatch);
      expect(resolution.stream, isNull);
    });

    test('trailers alone produce noPlayableSources', () async {
      final harness = _Harness(
        stream: _fixture('provider_stream_preview_only.json'),
      );
      final resolution = await harness.resolver.resolve(item: _movie());
      expect(resolution.isSuccess, isFalse);
      expect(resolution.errorType, ProviderErrorType.noPlayableSources);
    });

    test('a caption outage never blocks video playback', () async {
      final harness = _Harness(captionStatus: 500);
      final resolution = await harness.resolver.resolve(item: _movie());
      expect(resolution.isSuccess, isTrue);
      expect(resolution.stream!.captions, isEmpty);
      // A failed lookup is reported as failed, never as "no subtitles".
      expect(
        resolution.stream!.captionLoad.status,
        isNot(CaptionLoadStatus.empty),
      );
      expect(resolution.stream!.captionLoad.isLoaded, isFalse);
    });

    test('an explicit empty caption list is reported as empty', () async {
      final harness = _Harness(captions: '{"captions":[]}');
      final resolution = await harness.resolver.resolve(item: _movie());
      expect(resolution.isSuccess, isTrue);
      expect(resolution.stream!.captionLoad.status, CaptionLoadStatus.empty);
    });

    test('an unreadable caption payload is unsupported, not empty', () async {
      final harness = _Harness(captions: '{"captions":[{"language":"en"}]}');
      final resolution = await harness.resolver.resolve(item: _movie());
      expect(resolution.isSuccess, isTrue);
      expect(
        resolution.stream!.captionLoad.status,
        CaptionLoadStatus.unsupported,
      );
    });

    test('episode captions are requested with the episode se/ep values',
        () async {
      final harness = _Harness(
        search: _fixture('provider_search_tv.json'),
        stream: _fixture('provider_stream_episode.json'),
      );
      await harness.resolver.resolve(item: _show(), season: 5, episode: 1);
      final captionRequest = harness.last('/caption');
      expect(captionRequest.queryParameters['se'], '5');
      expect(captionRequest.queryParameters['ep'], '1');
    });

    test('a stream outage is reported as providerUnavailable', () async {
      final harness = _Harness(streamStatus: 502);
      final resolution = await harness.resolver.resolve(item: _movie());
      expect(resolution.isSuccess, isFalse);
      expect(resolution.errorType, ProviderErrorType.providerUnavailable);
    });

    test('ambiguous matches surface the candidate list', () async {
      final harness = _Harness(
        search: _fixture('provider_search_ambiguous.json'),
      );
      final item = MediaItem(
        id: 1,
        title: 'The Thing',
        overview: '',
        voteAverage: 0,
        releaseDate: '',
        mediaType: 'movie',
        genreIds: const [],
      );
      final resolution = await harness.resolver.resolve(item: item);
      expect(resolution.isSuccess, isFalse);
      expect(resolution.isAmbiguous, isTrue);
      expect(resolution.candidates, hasLength(2));
    });

    test('missing provider identifiers are diagnosable', () async {
      final harness = _Harness(
        search: _fixture('provider_search_missing_identifier.json'),
      );
      final resolution = await harness.resolver.resolve(item: _movie());
      expect(resolution.isSuccess, isFalse);
      expect(
        resolution.errorType,
        ProviderErrorType.missingProviderIdentifier,
      );
    });
  });

  group('Explicit provider matches', () {
    test('uses a supplied match without searching the provider', () async {
      final harness = _Harness();
      const match = ProviderMatch(
        subjectId: '42',
        detailPath: 'movie-slug',
        title: 'Inception',
        year: 2010,
        isSeries: false,
        confidence: 1,
      );

      final resolution = await harness.resolver.resolve(
        item: _movie(),
        providerMatch: match,
      );

      expect(resolution.isSuccess, isTrue);
      expect(harness.count('/search'), 0);
      expect(harness.lastStream().queryParameters['subjectId'], '42');
    });

    test('rejects a match whose detail path equals its subject id', () async {
      final harness = _Harness();
      const match = ProviderMatch(
        subjectId: '42',
        detailPath: '42',
        title: 'Inception',
        year: 2010,
        isSeries: false,
        confidence: 1,
      );

      final resolution = await harness.resolver.resolve(
        item: _movie(),
        providerMatch: match,
      );

      // A corrupt explicit match must never be sent upstream; the resolver
      // recovers by searching the provider with the title instead.
      expect(resolution.isSuccess, isTrue);
      expect(
        harness.requests.any((uri) => uri.path.endsWith('/play') && uri.queryParameters['subjectId'] == '42'),
        isFalse,
      );
    });
  });
}
