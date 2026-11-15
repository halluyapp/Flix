import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flix/models/caption_track.dart';
import 'package:flix/services/subtitle_service.dart';

CaptionTrack _track(String url) => CaptionTrack(
      id: 'en',
      language: 'en',
      languageName: 'English',
      url: url,
    );

void main() {
  group('SubtitleService parsing', () {
    test('parses SRT timestamps and identifies the active cue', () {
      final cues = SubtitleService.parseText('''1
00:00:01,500 --> 00:00:03,000
Hello from Flix.

2
00:00:04,000 --> 00:00:05,000
Second line.
''');

      expect(cues, hasLength(2));
      expect(cues.first.start, const Duration(milliseconds: 1500));
      expect(SubtitleService.activeText(cues, const Duration(seconds: 2)),
          'Hello from Flix.');
      expect(SubtitleService.activeText(cues, const Duration(seconds: 3)),
          isEmpty);
    });

    test('parses WebVTT cue identifiers and strips presentation tags', () {
      final cues = SubtitleService.parseText('''WEBVTT

intro
00:00:00.000 --> 00:00:02.250
<i>Welcome</i> &amp; enjoy.
''');

      expect(cues, hasLength(1));
      expect(cues.single.text, 'Welcome & enjoy.');
      expect(SubtitleService.activeText(cues, const Duration(seconds: 1)),
          'Welcome & enjoy.');
    });

    test('keeps non-Latin captions intact', () {
      final cues = SubtitleService.parseText('''1
00:00:01,000 --> 00:00:02,000
こんにちは
''');
      expect(cues.single.text, 'こんにちは');
    });
  });

  group('SubtitleService downloads', () {
    test('accepts a valid SRT file and reports its format and size', () async {
      final client = MockClient((_) async => http.Response(
            '1\n00:00:01,000 --> 00:00:02,000\nHello\n',
            200,
          ));
      addTearDown(client.close);

      final file = await SubtitleService.fetchValidated(
        _track('https://subs.example.com/en.srt'),
        client: client,
      );

      expect(file.extension, 'srt');
      expect(file.language, 'en');
      expect(file.text, contains('Hello'));
      expect(file.sizeBytes, greaterThan(0));
    });

    test('recognises WebVTT files', () async {
      final client = MockClient((_) async => http.Response(
            'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n',
            200,
          ));
      addTearDown(client.close);

      final file = await SubtitleService.fetchValidated(
        _track('https://subs.example.com/en.vtt'),
        client: client,
      );
      expect(file.extension, 'vtt');
    });

    test('rejects an HTML error page masquerading as subtitles', () async {
      final client = MockClient(
        (_) async => http.Response('<html><body>403</body></html>', 200),
      );
      addTearDown(client.close);

      await expectLater(
        SubtitleService.fetchValidated(
          _track('https://subs.example.com/en.srt'),
          client: client,
        ),
        throwsA(isA<SubtitleException>()),
      );
    });

    test('rejects a subtitle file with no readable cues', () async {
      final client = MockClient(
        (_) async => http.Response('this is not a subtitle file', 200),
      );
      addTearDown(client.close);

      await expectLater(
        SubtitleService.fetchValidated(
          _track('https://subs.example.com/en.srt'),
          client: client,
        ),
        throwsA(isA<SubtitleException>()),
      );
    });

    test('rejects an empty subtitle response', () async {
      final client = MockClient((_) async => http.Response('', 200));
      addTearDown(client.close);

      await expectLater(
        SubtitleService.fetchValidated(
          _track('https://subs.example.com/en.srt'),
          client: client,
        ),
        throwsA(isA<SubtitleException>()),
      );
    });

    test('rejects insecure subtitle URLs before any request', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('1\n00:00:01,000 --> 00:00:02,000\nHi', 200);
      });
      addTearDown(client.close);

      await expectLater(
        SubtitleService.fetchValidated(
          _track('http://subs.example.com/en.srt'),
          client: client,
        ),
        throwsA(isA<SubtitleException>()),
      );
      expect(calls, 0);
    });

    test('rejects TTML as unsupported instead of renaming it to .srt', () async {
      final client = MockClient((_) async => http.Response(
            '<?xml version="1.0"?><tt xmlns="http://www.w3.org/ns/ttml">'
            '<body><div><p begin="00:00:01.000" end="00:00:02.000">Hi</p>'
            '</div></body></tt>',
            200,
          ));
      addTearDown(client.close);

      await expectLater(
        SubtitleService.fetchValidated(
          _track('https://subs.example.com/en'),
          client: client,
        ),
        throwsA(
          isA<SubtitleException>().having(
            (e) => e.failure,
            'failure',
            SubtitleFailure.unsupportedFormat,
          ),
        ),
      );
    });

    test('accepts an ASS file without an extension in the URL', () async {
      final client = MockClient((_) async => http.Response(
            '[Script Info]\nScriptType: v4.00+\n\n[Events]\n'
            'Format: Layer, Start, End, Style, Name, MarginL, MarginR, '
            'MarginV, Effect, Text\n'
            'Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello\\Nthere\n',
            200,
          ));
      addTearDown(client.close);

      final file = await SubtitleService.fetchValidated(
        _track('https://subs.example.com/file?token=abc'),
        client: client,
      );
      expect(file.extension, 'ass');
      expect(file.text, contains('Dialogue:'));
    });

    test('decodes UTF-16 little-endian subtitle bytes with a BOM', () async {
      const text = '1\n00:00:01,000 --> 00:00:02,000\nمرحبا\n';
      final bytes = <int>[0xFF, 0xFE];
      for (final unit in text.codeUnits) {
        bytes.add(unit & 0xFF);
        bytes.add(unit >> 8);
      }
      expect(SubtitleService.decodeBytes(bytes), contains('مرحبا'));
    });

    test('a 401 is reported as expired so a fresh link can be requested', () async {
      final client = MockClient((_) async => http.Response('', 401));
      addTearDown(client.close);

      await expectLater(
        SubtitleService.fetchValidated(
          _track('https://subs.example.com/en.srt'),
          client: client,
        ),
        throwsA(
          isA<SubtitleException>()
              .having((e) => e.failure, 'failure', SubtitleFailure.expired)
              .having((e) => e.needsFreshLink, 'needsFreshLink', isTrue),
        ),
      );
    });

    test('a 403 with a fresh link is reported as denied', () async {
      final client = MockClient((_) async => http.Response('', 403));
      addTearDown(client.close);

      await expectLater(
        SubtitleService.fetchValidated(
          _track('https://subs.example.com/en.srt'),
          client: client,
        ),
        throwsA(
          isA<SubtitleException>().having(
            (e) => e.failure,
            'failure',
            SubtitleFailure.accessDenied,
          ),
        ),
      );
    });
  });
}
