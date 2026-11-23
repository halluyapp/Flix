import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flix/core/constants/api_constants.dart';
import 'package:flix/core/provider/provider_failures.dart';
import 'package:flix/services/moviebox_api_client.dart';

MovieBoxApiClient _client(
  http.Client mock, {
  int maxAttempts = 3,
  GuestToken? initialToken,
}) =>
    MovieBoxApiClient(
      client: mock,
      baseUrl: 'https://h5-api.aoneroom.com/wefeed-h5api-bff',
      maxAttempts: maxAttempts,
      defaultTimeout: const Duration(seconds: 1),
      sleep: (_) async {},
      initialToken: initialToken ?? const GuestToken(token: 'fixture-jwt'),
    );

void main() {
  group('MovieBoxApiClient guest token management', () {
    test('harvests token from /home x-user header when unauthenticated', () async {
      late Uri capturedHomeUri;
      late Uri capturedSearchUri;
      late Map<String, String> searchHeaders;

      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/home')) {
          capturedHomeUri = request.url;
          return http.Response(
            '{"code":0,"data":{}}',
            200,
            headers: {
              'x-user': '{"token":"harvested-guest-jwt","userId":"12345"}',
            },
          );
        }
        if (request.url.path.endsWith('/subject/search')) {
          capturedSearchUri = request.url;
          searchHeaders = request.headers;
          return http.Response('{"code":0,"data":{"items":[]}}', 200);
        }
        return http.Response('{}', 404);
      });
      addTearDown(mock.close);

      final client = MovieBoxApiClient(
        client: mock,
        baseUrl: 'https://h5-api.aoneroom.com/wefeed-h5api-bff',
        maxAttempts: 1,
        sleep: (_) async {},
      );

      final result = await client.postJson(
        '/subject/search',
        body: {'keyword': 'Inception'},
      );

      expect(result['code'], 0);
      expect(capturedHomeUri.path, '/wefeed-h5api-bff/home');
      expect(capturedHomeUri.queryParameters['host'], 'moviebox.ph');
      expect(capturedSearchUri.path, '/wefeed-h5api-bff/subject/search');
      expect(searchHeaders['Authorization'], 'Bearer harvested-guest-jwt');
    });

    test('refreshes token and retries on 401 auth failure', () async {
      var homeCalls = 0;
      var searchCalls = 0;

      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/home')) {
          homeCalls++;
          return http.Response(
            '{"code":0,"data":{}}',
            200,
            headers: {
              'x-user': '{"token":"refreshed-jwt-$homeCalls"}',
            },
          );
        }
        if (request.url.path.endsWith('/subject/search')) {
          searchCalls++;
          if (searchCalls == 1) {
            return http.Response('{"code":401,"message":"invalid token"}', 401);
          }
          return http.Response('{"code":0,"data":{"items":[]}}', 200);
        }
        return http.Response('{}', 404);
      });
      addTearDown(mock.close);

      final client = _client(mock, initialToken: const GuestToken(token: 'stale-jwt'));
      final result = await client.postJson('/subject/search', body: {'keyword': 'Inception'});

      expect(result['code'], 0);
      expect(searchCalls, 2);
      expect(homeCalls, 1);
    });

    test('captures rotated token from x-user on regular requests', () async {
      final mock = MockClient((request) async {
        return http.Response(
          '{"code":0,"data":{"items":[]}}',
          200,
          headers: {'x-user': '{"token":"rotated-jwt-999"}'},
        );
      });
      addTearDown(mock.close);

      final client = _client(mock, initialToken: const GuestToken(token: 'initial-jwt'));
      await client.getJson('/subject/play');
      expect(client.currentToken, 'rotated-jwt-999');
    });
  });

  group('MovieBoxApiClient request construction', () {
    test('builds the search request with POST body and MovieBox headers', () async {
      late Uri captured;
      late Map<String, String> headers;
      late String bodyText;

      final mock = MockClient((request) async {
        captured = request.url;
        headers = request.headers;
        bodyText = request.body;
        return http.Response('{"code":0,"data":{"items":[]}}', 200);
      });
      addTearDown(mock.close);

      await _client(mock).postJson(
        '/subject/search',
        query: {'host': ApiConstants.movieboxHost},
        body: {'keyword': 'Inception', 'page': 1, 'perPage': 30, 'subjectType': 0},
      );

      expect(captured.path, '/wefeed-h5api-bff/subject/search');
      expect(captured.queryParameters['host'], 'moviebox.ph');
      expect(bodyText, contains('"keyword":"Inception"'));
      expect(bodyText, contains('"subjectType":0'));
      expect(headers['Content-Type'], 'application/json');
      expect(headers['Referer'], 'https://moviebox.ph/');
      expect(headers['Origin'], 'https://moviebox.ph');
      expect(headers['Authorization'], 'Bearer fixture-jwt');
      expect(headers['X-Client-Info'], contains('Africa/Lagos'));
    });

    test('builds the play request with query parameters', () async {
      late Uri captured;
      final mock = MockClient((request) async {
        captured = request.url;
        return http.Response('{"code":0,"data":{"streams":[]}}', 200);
      });
      addTearDown(mock.close);

      await _client(mock).getJson(
        '/subject/play',
        query: {
          'subjectId': '1382465867459478920',
          'detailPath': 'breaking-bad-hindi',
          'se': '5',
          'ep': '1',
        },
      );

      expect(captured.path, '/wefeed-h5api-bff/subject/play');
      expect(captured.queryParameters['subjectId'], '1382465867459478920');
      expect(captured.queryParameters['detailPath'], 'breaking-bad-hindi');
      expect(captured.queryParameters['se'], '5');
      expect(captured.queryParameters['ep'], '1');
    });
  });

  group('MovieBoxApiClient failures', () {
    test('retries a transient server error and then succeeds', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        if (calls == 1) {
          return http.Response('{"error":"upstream_error"}', 503);
        }
        return http.Response('{"code":0,"data":{"items":[]}}', 200);
      });
      addTearDown(mock.close);

      final result = await _client(mock).getJson('/subject/search');
      expect(result['code'], 0);
      expect(calls, 2);
    });

    test('maps 429 to providerRateLimited after bounded retries', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        return http.Response('{"error":"rate_limited"}', 429);
      });
      addTearDown(mock.close);

      await expectLater(
        _client(mock).getJson('/subject/search'),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.type,
            'type',
            ProviderErrorType.providerRateLimited,
          ),
        ),
      );
      expect(calls, 3);
    });

    test('does not retry a permanent 403', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        return http.Response('{"error":"forbidden"}', 403);
      });
      addTearDown(mock.close);

      await expectLater(
        _client(mock).getJson(
          '/subject/play',
          kind: ProviderRequestKind.stream,
        ),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.type,
            'type',
            ProviderErrorType.playbackForbidden,
          ),
        ),
      );
      expect(calls, 1);
    });

    test('keeps the 401 status so an expired caption link can be told apart', () async {
      final mock = MockClient((_) async => http.Response('{}', 401));
      addTearDown(mock.close);

      await expectLater(
        _client(mock, maxAttempts: 1).getJson(
          '/subject/caption',
          kind: ProviderRequestKind.captions,
        ),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    });

    test('a caption lookup honours maxAttempts and stops early', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        return http.Response('upstream down', 503);
      });
      addTearDown(mock.close);

      await expectLater(
        _client(mock, maxAttempts: 2).getJson(
          '/subject/caption',
          kind: ProviderRequestKind.captions,
        ),
        throwsA(isA<ProviderException>()),
      );
      expect(calls, 2);
    });

    test('maps a malformed JSON body to invalidProviderResponse', () async {
      final mock = MockClient((_) async => http.Response('not json', 200));
      addTearDown(mock.close);

      await expectLater(
        _client(mock).getJson('/subject/search'),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.type,
            'type',
            ProviderErrorType.invalidProviderResponse,
          ),
        ),
      );
    });

    test('maps an empty body to invalidProviderResponse', () async {
      final mock = MockClient((_) async => http.Response('', 200));
      addTearDown(mock.close);

      await expectLater(
        _client(mock, maxAttempts: 1).getJson('/subject/search'),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.type,
            'type',
            ProviderErrorType.invalidProviderResponse,
          ),
        ),
      );
    });

    test('maps a timeout to providerTimeout', () async {
      final mock = MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return http.Response('{}', 200);
      });
      addTearDown(mock.close);

      await expectLater(
        _client(mock, maxAttempts: 1).getJson(
          '/subject/search',
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.type,
            'type',
            ProviderErrorType.providerTimeout,
          ),
        ),
      );
    });

    test('distinguishes a missing search result from an expired stream', () async {
      final mock = MockClient((_) async => http.Response('not found', 404));
      addTearDown(mock.close);

      await expectLater(
        _client(mock, maxAttempts: 1).getJson('/subject/search'),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.type,
            'type',
            ProviderErrorType.noProviderMatch,
          ),
        ),
      );

      await expectLater(
        _client(mock, maxAttempts: 1).getJson(
          '/subject/play',
          kind: ProviderRequestKind.stream,
        ),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.type,
            'type',
            ProviderErrorType.streamExpired,
          ),
        ),
      );
    });

    test('keeps provider diagnostics free of signed URLs', () async {
      final mock = MockClient(
        (_) async => http.Response(
          '{"error":"upstream_error","message":"https://cdn.example.com/x.mp4?sign=secret"}',
          502,
        ),
      );
      addTearDown(mock.close);

      try {
        await _client(mock, maxAttempts: 1).getJson(
          '/subject/play?detailPath=inception',
        );
        fail('expected a ProviderException');
      } on ProviderException catch (error) {
        expect(error.diagnostic, contains('upstream_error'));
        expect(error.diagnostic, isNot(contains('sign=secret')));
        expect(error.message, isNot(contains('cdn.example.com')));
      }
    });

    test('maps MovieBox business error codes (code != 0)', () async {
      final mock = MockClient(
        (_) async => http.Response(
          '{"code":10001,"message":"resource not found"}',
          200,
        ),
      );
      addTearDown(mock.close);

      await expectLater(
        _client(mock, maxAttempts: 1).getJson(
          '/subject/search',
          kind: ProviderRequestKind.search,
        ),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.type,
            'type',
            ProviderErrorType.noProviderMatch,
          ),
        ),
      );
    });
  });
}
