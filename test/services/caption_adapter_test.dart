import 'package:flutter_test/flutter_test.dart';

import 'package:flix/core/provider/provider_failures.dart';
import 'package:flix/models/caption_load.dart';
import 'package:flix/services/caption_adapter.dart';

void main() {
  group('CaptionResponseAdapter', () {
    test('reads a flat captions list', () {
      final load = CaptionResponseAdapter.parse({
        'captions': [
          {
            'lan': 'English',
            'lanCode': 'en',
            'url': 'https://subs.example.com/a.srt',
          },
        ],
      });
      expect(load.status, CaptionLoadStatus.loaded);
      expect(load.tracks.single.language, 'en');
    });

    test('reads a nested data wrapper', () {
      final load = CaptionResponseAdapter.parse({
        'success': true,
        'data': {
          'captions': [
            {'language': 'ar', 'url': 'https://subs.example.com/ar.vtt'},
          ],
        },
      });
      expect(load.status, CaptionLoadStatus.loaded);
      expect(load.tracks.single.language, 'ar');
    });

    test('reads a list that arrives as a JSON string', () {
      final load = CaptionResponseAdapter.parse({
        'captions':
            '[{"language":"fr","url":"https://subs.example.com/fr.srt"}]',
      });
      expect(load.status, CaptionLoadStatus.loaded);
      expect(load.tracks.single.language, 'fr');
    });

    test('reads a by-language map and keeps the language key', () {
      final load = CaptionResponseAdapter.parse({
        'subtitles': {
          'en': {'url': 'https://subs.example.com/en.srt'},
          'es': {'url': 'https://subs.example.com/es.vtt'},
        },
      });
      expect(load.status, CaptionLoadStatus.loaded);
      expect(load.tracks.map((t) => t.language).toSet(), {'en', 'es'});
    });

    test('an explicit empty list is empty, not unsupported', () {
      final load = CaptionResponseAdapter.parse({'captions': []});
      expect(load.status, CaptionLoadStatus.empty);
    });

    test('an unreadable collection is unsupported, never empty', () {
      final load = CaptionResponseAdapter.parse({
        'captions': [
          {'language': 'en'},
          {'url': 'ftp://subs.example.com/en.srt'},
        ],
      });
      expect(load.status, CaptionLoadStatus.unsupported);
      expect(load.tracks, isEmpty);
    });

    test('a response with no readable collection is unsupported', () {
      final load = CaptionResponseAdapter.parse({'message': 'hello'});
      expect(load.status, CaptionLoadStatus.unsupported);
    });

    test('a provider error object is thrown, not turned into a list', () {
      expect(
        () => CaptionResponseAdapter.parse({
          'success': false,
          'error': 'subtitle lookup failed',
        }),
        throwsA(isA<ProviderException>()),
      );
    });

    test('a non-object root is an invalid provider response', () {
      expect(
        () => CaptionResponseAdapter.parse(['not', 'an', 'object']),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.type,
            'type',
            ProviderErrorType.invalidProviderResponse,
          ),
        ),
      );
    });

    test('keeps two tracks in the same language as separate tracks', () {
      final load = CaptionResponseAdapter.parse({
        'captions': [
          {
            'language': 'en',
            'label': 'English',
            'url': 'https://subs.example.com/en-1.srt',
          },
          {
            'language': 'en',
            'label': 'English SDH',
            'url': 'https://subs.example.com/en-2.srt',
          },
        ],
      });
      expect(load.tracks, hasLength(2));
    });
  });
}
