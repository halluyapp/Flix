import 'package:flutter_test/flutter_test.dart';
import 'package:flix/services/subtitle_service.dart';

void main() {
  group('SubtitleService', () {
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
  });
}
