import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flix/models/stream_source.dart';
import 'package:flix/services/media_probe.dart';

StreamSource _source() => StreamSource(
      url: 'https://media.example.com/movie-480.mp4',
      resolution: '480p',
      qualityValue: 480,
      format: 'MP4',
      formatKind: StreamFormat.mp4,
      sizeBytes: 700000000,
      durationSeconds: 5000,
      isPreview: false,
      verifiedFullLength: true,
    );

void main() {
  test('treats a 206 range response as playable', () async {
    final client = MockClient((_) async => http.Response('', 206));
    final probe = MediaProbe(client: client);

    final result = await probe.check(_source());

    expect(result.reachable, isTrue);
    expect(result.blocked, isFalse);
    expect(result.statusCode, 206);
  });

  test('sends a range request with the verified media headers', () async {
    final seen = <http.BaseRequest>[];
    final client = MockClient((request) async {
      seen.add(request);
      return http.Response('', 206);
    });

    await MediaProbe(client: client).check(_source());

    expect(seen, hasLength(1));
    expect(seen.single.headers['Range'], 'bytes=0-1');
    expect(seen.single.headers['User-Agent'], contains('Mozilla/5.0'));
    expect(seen.single.headers['Referer'], 'https://moviebox.ph/');
  });

  test('retries a 429 once before giving up', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('', calls == 1 ? 429 : 206);
    });

    final result = await MediaProbe(
      client: client,
      retryDelay: Duration.zero,
    ).check(_source());

    expect(result.reachable, isTrue);
    expect(calls, 2);
  });

  test('reports a blocked link with its HTTP status', () async {
    final client = MockClient((_) async => http.Response('', 403));

    final result = await MediaProbe(
      client: client,
      retryDelay: Duration.zero,
    ).check(_source());

    expect(result.reachable, isFalse);
    expect(result.inconclusive, isFalse);
    expect(result.blocked, isTrue);
    expect(result.statusCode, 403);
    expect(result.description, 'HTTP 403');
  });

  test('a transport failure is inconclusive, not a block', () async {
    final client = MockClient((_) async => throw const SocketException('down'));

    final result = await MediaProbe(client: client).check(_source());

    expect(result.blocked, isFalse);
    expect(result.inconclusive, isTrue);
    expect(result.reachable, isTrue);
  });
}
