import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flix/core/constants/api_constants.dart';
import 'package:flix/models/media_item.dart';
import 'package:flix/models/provider_clip.dart';
import 'package:flix/models/provider_match.dart';
import 'package:flix/services/zarhosting_api_client.dart';
import 'package:flix/services/zarhosting_service.dart';

void main() {
  group('MovieBox H5 API Integration', () {
    test('search uses POST /subject/search with payload structure', () async {
      Uri? capturedUrl;
      String? capturedBody;
      Map<String, String>? capturedHeaders;

      final mock = MockClient((request) async {
        capturedUrl = request.url;
        capturedBody = request.body;
        capturedHeaders = request.headers;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'items': [
                {
                  'subjectId': '1577289319553844304',
                  'title': 'Queen of Tears',
                  'subjectType': 2,
                  'releaseDate': '2024-03-09',
                  'detailPath': 'queen-of-tears-y9gk8Z60wS1',
                  'hasResource': true,
                  'genre': 'Drama,Romance',
                }
              ]
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = ZarhostingApiClient(
        client: mock,
        baseUrl: ApiConstants.movieboxH5BaseUrl,
        defaultTimeout: const Duration(seconds: 1),
        sleep: (_) async {},
      );
      final service = ZarhostingService(client: client);

      final result = await service.findMatch(
        title: 'Queen of Tears',
        year: 2024,
        isSeries: true,
      );

      expect(capturedUrl?.path, contains('/subject/search'));
      expect(capturedBody, contains('"keyword":"Queen of Tears"'));
      expect(capturedHeaders?['accept'], 'application/json');
      expect(result.isMatched, isTrue);
      expect(result.match?.subjectId, '1577289319553844304');
      expect(result.match?.detailPath, 'queen-of-tears-y9gk8Z60wS1');
    });

    test('play uses GET /subject/play with required params and referer', () async {
      Uri? capturedUrl;
      Map<String, String>? capturedHeaders;

      final mock = MockClient((request) async {
        capturedUrl = request.url;
        capturedHeaders = request.headers;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'hasResource': true,
              'streams': [
                {
                  'id': '2758339355793048576',
                  'format': 'MP4',
                  'resolution': '1080p',
                  'size': 1234567890,
                  'url': 'https://stream.example.test/video.mp4',
                  'vipLocked': false,
                }
              ],
              'dash': [
                {
                  'url': 'https://stream.example.test/manifest.mpd',
                  'format': 'DASH',
                  'signCookie': 'token=abc',
                }
              ]
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = ZarhostingApiClient(
        client: mock,
        baseUrl: ApiConstants.movieboxH5BaseUrl,
        defaultTimeout: const Duration(seconds: 1),
        sleep: (_) async {},
      );
      final service = ZarhostingService(client: client);

      const match = ProviderMatch(
        subjectId: '1577289319553844304',
        detailPath: 'queen-of-tears-y9gk8Z60wS1',
        title: 'Queen of Tears',
        year: 2024,
        isSeries: true,
        confidence: 1.0,
      );

      final sources = await service.resolveStreams(
        match: match,
        season: 1,
        episode: 1,
      );

      expect(capturedUrl?.path, contains('/subject/play'));
      expect(capturedUrl?.queryParameters['subjectId'], '1577289319553844304');
      expect(capturedUrl?.queryParameters['se'], '1');
      expect(capturedUrl?.queryParameters['ep'], '1');
      expect(capturedHeaders?['Referer'], contains('queen-of-tears-y9gk8Z60wS1'));

      expect(sources, hasLength(2));
      final mp4 = sources.firstWhere((s) => s.isMp4);
      expect(mp4.resolution, '1080p');
      expect(mp4.isDownloadable, isTrue);
      expect(mp4.headers['Referer'], 'https://mzfi.me/');

      final dash = sources.firstWhere((s) => s.isDash);
      expect(dash.headers['Cookie'], 'token=abc');
      expect(dash.isDownloadable, isFalse);
    });

    test('caption uses GET /subject/caption and parses tracks', () async {
      Uri? capturedUrl;

      final mock = MockClient((request) async {
        capturedUrl = request.url;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'captions': [
                {
                  'id': '101',
                  'lan': 'en',
                  'lanName': 'English',
                  'url': 'https://caption.example.test/en.srt',
                },
                {
                  'id': '102',
                  'lan': 'ar',
                  'lanName': 'العربية',
                  'url': 'https://caption.example.test/ar.srt',
                }
              ]
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = ZarhostingApiClient(
        client: mock,
        baseUrl: ApiConstants.movieboxH5BaseUrl,
        defaultTimeout: const Duration(seconds: 1),
        sleep: (_) async {},
      );
      final service = ZarhostingService(client: client);

      const match = ProviderMatch(
        subjectId: '1577289319553844304',
        detailPath: 'queen-of-tears-y9gk8Z60wS1',
        title: 'Queen of Tears',
        year: 2024,
        isSeries: true,
        confidence: 1.0,
      );

      final captionLoad = await service.fetchCaptionLoad(
        match: match,
        season: 1,
        episode: 1,
        streamId: '2758339355793048576',
      );

      expect(capturedUrl?.path, contains('/subject/caption'));
      expect(capturedUrl?.queryParameters['id'], '2758339355793048576');
      expect(captionLoad.isLoaded, isTrue);
      expect(captionLoad.tracks, hasLength(2));
      expect(captionLoad.tracks.first.language, 'en');
      expect(captionLoad.tracks.first.languageName, 'English');
    });

    test('ProviderClip parses MovieBox numeric type 1 and nested cover', () {
      final json = {
        'subjectId': '987654321',
        'title': 'Bao',
        'subjectType': 1,
        'releaseDate': '2018-06-15',
        'detailPath': 'bao-2018',
        'genre': 'Animation,Short,Family',
        'score': 8.2,
        'hasResource': true,
        'cover': {
          'url': 'https://img.example.test/bao.jpg',
        },
      };

      final clip = ProviderClip.fromProviderJson(json);
      expect(clip, isNotNull);
      expect(clip!.title, 'Bao');
      expect(clip.year, 2018);
      expect(clip.posterUrl, 'https://img.example.test/bao.jpg');
      expect(clip.isPornographic, isFalse);
    });
  });
}
