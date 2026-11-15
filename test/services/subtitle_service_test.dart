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
      final cues = SubtitleService.parse('''1
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
      final cues = SubtitleService.parse('''WEBVTT

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
      final cues = SubtitleService.parse('''1
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
        throwsFormatException,
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
        throwsFormatException,
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
        throwsFormatException,
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
        throwsFormatException,
      );
      expect(calls, 0);
    });
  });
}
