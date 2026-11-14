import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flix/services/tmdb_service.dart';

void main() {
  group('TmdbService Supabase response status', () {
    test('records a successful proxy response even when the catalogue is empty', () async {
      final client = MockClient((request) async {
        expect(request.url.path, endsWith('/functions/v1/tmdb-proxy'));
        expect(request.url.queryParameters['path'], '/trending/all/day');
        return http.Response(jsonEncode({'results': <dynamic>[]}), 200);
      });
      addTearDown(client.close);

      final service = TmdbService(client: client);

      expect(service.hasSuccessfulSupabaseResponse, isFalse);
      expect(await service.getTrending(), isEmpty);
      expect(service.hasSuccessfulSupabaseResponse, isTrue);
    });

    test('does not mark the proxy connected for a failed HTTP response', () async {
      final client = MockClient((_) async => http.Response('unavailable', 503));
      addTearDown(client.close);

      final service = TmdbService(client: client);

      expect(await service.getTrending(), isEmpty);
      expect(service.hasSuccessfulSupabaseResponse, isFalse);
    });

    test('resets connection evidence before a new refresh', () async {
      var statusCode = 200;
      final client = MockClient((_) async =>
          http.Response(jsonEncode({'results': <dynamic>[]}), statusCode));
      addTearDown(client.close);

      final service = TmdbService(client: client);
      await service.getTrending();
      expect(service.hasSuccessfulSupabaseResponse, isTrue);

      service.resetSupabaseConnectionStatus();
      expect(service.hasSuccessfulSupabaseResponse, isFalse);

      statusCode = 503;
      await service.getTrending();
      expect(service.hasSuccessfulSupabaseResponse, isFalse);
    });
  });
}
