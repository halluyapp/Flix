import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flix/core/provider/provider_failures.dart';
import 'package:flix/services/zarhosting_api_client.dart';

ZarhostingApiClient _client(
  http.Client mock, {
  int maxAttempts = 3,
}) =>
    ZarhostingApiClient(
      client: mock,
      baseUrl: 'https://provider.example.com/api/public/v1',
      maxAttempts: maxAttempts,
      defaultTimeout: const Duration(seconds: 1),
      sleep: (_) async {},
    );

void main() {
  group('ZarhostingApiClient request construction', () {
    test('builds the search request with the provider parameters and headers',
        () async {
      late Uri captured;
      late Map<String, String> headers;
      final mock = MockClient((request) async {
        captured = request.url;
        headers = request.headers;
        return http.Response('{"items":[]}', 200);
      });
      addTearDown(mock.close);

      await _client(mock).getJson(
        '/search',
        query: {'q': 'Inception', 'page': '1', 'per_page': '30'},
      );

      expect(captured.path, '/api/public/v1/search');
      expect(captured.queryParameters['q'], 'Inception');
      expect(captured.queryParameters['page'], '1');
      expect(captured.queryParameters['per_page'], '30');
      expect(
        headers.entries.any(
          (entry) =>
              entry.key.toLowerCase() == 'accept' &&
              entry.value == 'application/json',
        ),
        isTrue,
      );
    });

    test('encodes the subject id into the stream path', () async {
      late Uri captured;
      final mock = MockClient((request) async {
        captured = request.url;
        return http.Response('{"sources":[]}', 200);
      });
      addTearDown(mock.close);

      await _client(mock).getJson(
        '/stream/${Uri.encodeComponent('1382465867459478920')}',
        query: {'detail_path': 'breaking-bad-hindi', 'se': '5', 'ep': '1'},
      );

      expect(
        captured.path,
        '/api/public/v1/stream/1382465867459478920',
      );
      expect(captured.queryParameters['detail_path'], 'breaking-bad-hindi');
      expect(captured.queryParameters['se'], '5');
      expect(captured.queryParameters['ep'], '1');
    });
  });

  group('ZarhostingApiClient failures', () {
    test('retries a transient server error and then succeeds', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        if (calls == 1) {
          return http.Response('{"error":"upstream_error"}', 503);
        }
        return http.Response('{"items":[]}', 200);
      });
      addTearDown(mock.close);

      final result = await _client(mock).getJson('/search');
      expect(result['items'], isEmpty);
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
        _client(mock).getJson('/search'),
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
          '/stream/1',
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

    test('maps a malformed JSON body to invalidProviderResponse', () async {
      final mock = MockClient((_) async => http.Response('not json', 200));
      addTearDown(mock.close);

      await expectLater(
        _client(mock).getJson('/search'),
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
        _client(mock, maxAttempts: 1).getJson('/search'),
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
          '/search',
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
        _client(mock, maxAttempts: 1).getJson('/search'),
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
          '/stream/1',
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
          '/stream/1?detail_path=inception',
        );
        fail('expected a ProviderException');
      } on ProviderException catch (error) {
        expect(error.diagnostic, contains('upstream_error'));
        expect(error.diagnostic, isNot(contains('sign=secret')));
        expect(error.message, isNot(contains('cdn.example.com')));
      }
    });
  });
}
